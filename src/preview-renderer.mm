/*
Non-Blocking Previews
Copyright (C) 2026 Alekstyle

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program. If not, see <https://www.gnu.org/licenses/>
*/

#include "preview-renderer.hpp"

#include "gl-scaler.hpp"

#include <obs.h>
#include <graphics/graphics.h>
#include <util/profiler.h>
#include <plugin-support.h>

#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <OpenGL/gl3.h>

#include <algorithm>
#include <cmath>

#ifdef NBP_RENDERER_TIMING
#include <util/platform.h>
#define NBP_TIME_BEGIN(name) const uint64_t nbpStart_##name = os_gettime_ns()
#define NBP_TIME_END(name) lastTiming.name = os_gettime_ns() - nbpStart_##name
#else
#define NBP_TIME_BEGIN(name) ((void)0)
#define NBP_TIME_END(name) ((void)0)
#endif

namespace nbp {

namespace {

const char *const kProfileRecreate = "nbp_recreate_surfaces";

/* Tamaño de la imagen dentro del dock: proporciones del lienzo, sin superar
 * el área del dock ni el tamaño del propio lienzo. */
void fitSize(uint64_t requested, uint32_t sourceWidth, uint32_t sourceHeight, uint32_t &width, uint32_t &height)
{
	const double areaWidth = PreviewShared::unpackWidth(requested);
	const double areaHeight = PreviewShared::unpackHeight(requested);
	const double scale = std::min({areaWidth / sourceWidth, areaHeight / sourceHeight, 1.0});

	width = std::max<uint32_t>(1, uint32_t(std::lround(sourceWidth * scale)));
	height = std::max<uint32_t>(1, uint32_t(std::lround(sourceHeight * scale)));
}

IOSurfaceRef createSurface(uint32_t width, uint32_t height)
{
	@autoreleasepool {
		const size_t bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, size_t(width) * 4);
		NSDictionary *properties = @{
			(id)kIOSurfaceWidth: @(width),
			(id)kIOSurfaceHeight: @(height),
			(id)kIOSurfaceBytesPerElement: @4,
			(id)kIOSurfaceBytesPerRow: @(bytesPerRow),
			(id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
		};

		IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
		if (!surface)
			return nullptr;

		/* El lienzo de OBS es SDR sRGB/Rec. 709: etiquetarlo así permite que
		 * Core Animation gestione el color igual que con cualquier ventana. */
		CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
		if (colorSpace) {
			CFPropertyListRef colorSpaceProperties = CGColorSpaceCopyPropertyList(colorSpace);
			if (colorSpaceProperties) {
				IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpaceProperties);
				CFRelease(colorSpaceProperties);
			}
			CGColorSpaceRelease(colorSpace);
		}

		return surface;
	}
}

GLuint textureName(gs_texture_t *texture)
{
	void *object = gs_texture_get_obj(texture);
	return object ? *static_cast<GLuint *>(object) : 0;
}

} // namespace

PreviewRenderer::PreviewRenderer(PreviewShared &shared, GlScaler &scaler, const char *profileName)
	: shared_(shared),
	  scaler_(scaler),
	  profileName_(profileName)
{
}

bool PreviewRenderer::wantsFrame(uint64_t frameTime, uint64_t frameIntervalNs) const
{
	if (shared_.requestedSize.load(std::memory_order_relaxed) == 0)
		return false;

	const uint32_t limit = shared_.fpsLimit.load(std::memory_order_relaxed);
	if (limit == 0 || lastFrameTime_ == 0)
		return true;

	/* Media duración de fotograma de tolerancia para que, p. ej., 30 FPS
	 * sobre 60 dibuje exactamente uno de cada dos. */
	const uint64_t interval = 1000000000ULL / limit;
	return frameTime - lastFrameTime_ + frameIntervalNs / 2 >= interval;
}

void PreviewRenderer::render(gs_texture_t *source, uint64_t frameTime)
{
	const uint64_t requested = shared_.requestedSize.load(std::memory_order_relaxed);
	if (!requested || !source)
		return;

	const uint32_t sourceWidth = gs_texture_get_width(source);
	const uint32_t sourceHeight = gs_texture_get_height(source);
	if (!sourceWidth || !sourceHeight)
		return;

	profile_start(profileName_);

	uint32_t width = 0;
	uint32_t height = 0;
	fitSize(requested, sourceWidth, sourceHeight, width, height);

	Slot *slot = nullptr;
	if (scaler_.ensure() && ensureResources(width, height)) {
		NBP_TIME_BEGIN(acquire);
		slot = acquireSlot();
		NBP_TIME_END(acquire);
	}

	if (!slot) {
		shared_.framesSkippedBusy.fetch_add(1, std::memory_order_relaxed);
		profile_end(profileName_);
		return;
	}

	lastFrameTime_ = frameTime;

	NBP_TIME_BEGIN(draw);
	scaler_.draw(textureName(source), sourceWidth, sourceHeight, slot->fbo, width_, height_);
	NBP_TIME_END(draw);

	/* La superficie se publicará cuando la GPU haya terminado. OBS hace
	 * gs_flush() al final de cada mezcla y el primer sondeo usa
	 * GL_SYNC_FLUSH_COMMANDS_BIT, así que aquí no hace falta glFlush(). */
	NBP_TIME_BEGIN(fence);
	slot->fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
	NBP_TIME_END(fence);
	slot->flushed = false;
	slot->ready = false;
	slot->serial = ++serial_;

	profile_end(profileName_);
}

void PreviewRenderer::poll()
{
	NBP_TIME_BEGIN(poll);
	Slot *newest = nullptr;

	for (Slot &slot : slots_) {
		if (slot.fence) {
			const GLenum status =
				glClientWaitSync(slot.fence, slot.flushed ? 0 : GL_SYNC_FLUSH_COMMANDS_BIT, 0);
			slot.flushed = true;

			if (status == GL_ALREADY_SIGNALED || status == GL_CONDITION_SATISFIED) {
				glDeleteSync(slot.fence);
				slot.fence = nullptr;
				slot.ready = true;
			} else if (status == GL_WAIT_FAILED) {
				glDeleteSync(slot.fence);
				slot.fence = nullptr;
			}
		}

		if (slot.ready && (!newest || slot.serial > newest->serial))
			newest = &slot;
	}

	NBP_TIME_END(poll);
	if (!newest)
		return;

	/* Las superficies listas pero más antiguas ya no interesan. */
	for (Slot &slot : slots_) {
		if (slot.ready && &slot != newest)
			slot.ready = false;
	}

	if (!os_unfair_lock_trylock(&shared_.lock))
		return; /* Se reintenta en el siguiente sondeo. */

	IOSurfaceRef previous = shared_.latest;
	shared_.latest = (IOSurfaceRef)CFRetain(newest->surface);
	shared_.latestSerial++;
	os_unfair_lock_unlock(&shared_.lock);

	if (previous)
		CFRelease(previous);

	newest->ready = false;
	shared_.framesPublished.fetch_add(1, std::memory_order_relaxed);
}

PreviewRenderer::Slot *PreviewRenderer::acquireSlot()
{
	if (!os_unfair_lock_trylock(&shared_.lock))
		return nullptr;
	IOSurfaceRef latest = shared_.latest;
	IOSurfaceRef displayed = shared_.displayed;
	os_unfair_lock_unlock(&shared_.lock);

	/* El hilo principal solo puede pasar `displayed` a `latest`, que también
	 * excluimos, así que la comprobación sigue siendo válida tras soltar el
	 * cerrojo. IOSurfaceIsInUse() cubre lo que aún compone WindowServer. */
	for (Slot &slot : slots_) {
		if (slot.fence || slot.ready)
			continue;
		if (slot.surface == latest || slot.surface == displayed)
			continue;
		if (IOSurfaceIsInUse(slot.surface))
			continue;
		return &slot;
	}

	return nullptr;
}

bool PreviewRenderer::ensureResources(uint32_t width, uint32_t height)
{
	if (slots_[0].surface && width == width_ && height == height_)
		return true;

	const uint64_t packed = PreviewShared::packSize(width, height);
	if (failed_ && failedSize_ == packed)
		return false;

	profile_start(kProfileRecreate);
	NBP_TIME_BEGIN(recreate);

	destroy();

	GLint previousFramebuffer = 0;
	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previousFramebuffer);

	bool ok = true;
	for (Slot &slot : slots_) {
		slot.surface = createSurface(width, height);
		if (slot.surface)
			slot.texture = gs_texture_create_from_iosurface(slot.surface);
		if (!slot.texture) {
			ok = false;
			break;
		}

		/* La textura es GL_TEXTURE_RECTANGLE y libobs-opengl no la admite
		 * como render target: se usa un FBO propio. */
		glGenFramebuffers(1, &slot.fbo);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, slot.fbo);
		glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE,
				       textureName(slot.texture), 0);
		if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
			ok = false;
			break;
		}
	}

	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(previousFramebuffer));

	if (ok) {
		width_ = width;
		height_ = height;
		failed_ = false;
		obs_log(LOG_INFO, "%s: superficies %ux%u creadas", profileName_, width, height);
	} else {
		destroy();
		failed_ = true;
		failedSize_ = packed;
		obs_log(LOG_ERROR, "%s: no se pudieron crear las superficies %ux%u", profileName_, width, height);
	}

	NBP_TIME_END(recreate);
	profile_end(kProfileRecreate);
	return ok;
}

void PreviewRenderer::destroy()
{
	for (Slot &slot : slots_) {
		if (slot.fence)
			glDeleteSync(slot.fence);
		if (slot.fbo)
			glDeleteFramebuffers(1, &slot.fbo);
		if (slot.texture)
			gs_texture_destroy(slot.texture);
		/* Si Core Animation o `shared_.latest` la siguen usando, conservan
		 * su propia referencia. */
		if (slot.surface)
			CFRelease(slot.surface);
		slot = Slot{};
	}

	width_ = 0;
	height_ = 0;
}

} // namespace nbp
