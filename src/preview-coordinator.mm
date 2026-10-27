/*
Optimized Previews
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

#include "preview-coordinator.hpp"

#include <obs.h>
#include <graphics/graphics.h>
#include <util/bmem.h>
#include <util/profiler.h>
#include <plugin-support.h>

#include <CoreFoundation/CoreFoundation.h>

#include <OpenGL/gl3.h>
#include <OpenGL/gl3ext.h>

#ifndef GL_DECODE_EXT
#define GL_DECODE_EXT 0x8A49
#endif

namespace op {

namespace {

const char *const kProfileCallback = "op_rendered_callback";
const char *const kProfilePoll = "op_poll";
const char *const kProfileMain = "op_preview_main";
const char *const kProfileVertical = "op_preview_vertical";
const char *const kProfileVerify = "op_verify_vertical_texture";

constexpr uint64_t kSecond = 1000000000ULL;
/* Se vuelve a verificar la textura del canvas vertical con esta cadencia,
 * además de tras cada video_reset del canvas. */
constexpr uint64_t kReverifyIntervalNs = 5 * kSecond;
/* Si la textura verificada deja de aparecer, se busca de nuevo. */
constexpr uint64_t kVerticalLostNs = 2 * kSecond;
/* Los candidatos descartados se vuelven a probar pasado este tiempo. */
constexpr uint64_t kRejectedExpiryNs = 2 * kSecond;
constexpr size_t kMaxRejected = 16;
/* Aviso en el log si el canvas existe pero su textura no aparece. */
constexpr uint64_t kNotFoundWarningNs = 10 * kSecond;

GLuint textureName(gs_texture_t *texture)
{
	void *object = gs_texture_get_obj(texture);
	return object ? *static_cast<GLuint *>(object) : 0;
}

/* Lee o escribe GL_TEXTURE_SRGB_DECODE_EXT de una textura 2D, restaurando
 * el enlace de la unidad 0 y la unidad activa. */
GLint textureDecodeMode(GLuint texture, GLint newMode)
{
	GLint activeTexture = 0, binding = 0, mode = 0;
	glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
	glActiveTexture(GL_TEXTURE0);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &binding);
	glBindTexture(GL_TEXTURE_2D, texture);
	if (newMode)
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SRGB_DECODE_EXT, newMode);
	else
		glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_SRGB_DECODE_EXT, &mode);
	glBindTexture(GL_TEXTURE_2D, GLuint(binding));
	glActiveTexture(GLenum(activeTexture));
	return mode;
}

} // namespace

PreviewCoordinator::PreviewCoordinator()
	: mainRenderer_(mainShared, scaler_, kProfileMain),
	  verticalRenderer_(verticalShared, scaler_, kProfileVertical)
{
}

/* ¿Es `candidate` la textura en la que libobs compone `canvas`?
 *
 * No hay API pública que la devuelva, y comparar solo el tamaño no basta
 * (Source Record y las mezclas multipista crean otras de igual tamaño).
 * libobs-opengl, cada vez que enlaza una textura para dibujar, fija en ella
 * GL_TEXTURE_SRGB_DECODE_EXT (DECODE en la variante sRGB). Se marca el
 * candidato con SKIP_DECODE, se dibuja el canvas con la API pública
 * obs_render_canvas_texture_src_color_only() en un render target propio de
 * 2×2 y se comprueba si la marca ha cambiado a DECODE. Cualquier uso
 * posterior de la textura por libobs vuelve a fijar ese parámetro, así que
 * la marca no afecta a OBS. */
bool PreviewCoordinator::verifyCanvasTexture(gs_texture_t *candidate, obs_canvas_t *canvas)
{
	const GLuint name = textureName(candidate);
	if (!name)
		return false;

	if (!probeTarget_)
		probeTarget_ = gs_texture_create(2, 2, GS_BGRA, 1, nullptr, GS_RENDER_TARGET);
	if (!probeTarget_)
		return false;

	profile_start(kProfileVerify);

	textureDecodeMode(name, GL_SKIP_DECODE_EXT);

	gs_texture_t *previousTarget = gs_get_render_target();
	gs_zstencil_t *previousZStencil = gs_get_zstencil_target();
	const enum gs_color_space previousSpace = gs_get_color_space();
	gs_viewport_push();
	gs_projection_push();
	gs_matrix_push();
	gs_matrix_identity();

	gs_set_render_target_with_color_space(probeTarget_, nullptr, GS_CS_SRGB);
	gs_set_viewport(0, 0, 2, 2);
	gs_ortho(0.0f, 2.0f, 0.0f, 2.0f, -100.0f, 100.0f);
	obs_render_canvas_texture_src_color_only(canvas);

	gs_set_render_target_with_color_space(previousTarget, previousZStencil, previousSpace);
	gs_matrix_pop();
	gs_projection_pop();
	gs_viewport_pop();

	const bool match = textureDecodeMode(name, 0) == GL_DECODE_EXT;

	profile_end(kProfileVerify);
	return match;
}

void PreviewCoordinator::forgetVerticalTexture()
{
	verticalTexture_ = nullptr;
	rejected_.clear();
}

/* Decide si el render target de este callback es el canvas vertical. Solo
 * se compara con punteros vistos como render target en este mismo
 * callback, que es la prueba de que siguen vivos. */
bool PreviewCoordinator::isVerticalTexture(gs_texture_t *candidate, obs_canvas_t *canvas, uint64_t frameTime)
{
	if (candidate == verticalTexture_) {
		verticalSeenAt_ = frameTime;
		if (frameTime - verifiedAt_ < kReverifyIntervalNs)
			return true;
		if (verifyCanvasTexture(candidate, canvas)) {
			verifiedAt_ = frameTime;
			return true;
		}
		verticalTexture_ = nullptr;
	} else if (verticalTexture_) {
		return false;
	}

	if (!rejected_.empty() && frameTime - rejectedSince_ >= kRejectedExpiryNs)
		rejected_.clear();
	for (gs_texture_t *rejected : rejected_) {
		if (rejected == candidate)
			return false;
	}

	if (verifyCanvasTexture(candidate, canvas)) {
		verticalTexture_ = candidate;
		verifiedAt_ = frameTime;
		verticalSeenAt_ = frameTime;
		rejected_.clear();
		obs_log(LOG_INFO, "textura del canvas vertical identificada");
		return true;
	}

	if (rejected_.empty())
		rejectedSince_ = frameTime;
	if (rejected_.size() < kMaxRejected)
		rejected_.push_back(candidate);
	return false;
}

void PreviewCoordinator::onBeforeRender()
{
	if (!checkedRenderer.load(std::memory_order_relaxed) || unsupportedRenderer.load(std::memory_order_relaxed))
		return;

	profile_start(kProfilePoll);
	mainRenderer_.poll();
	verticalRenderer_.poll();
	profile_end(kProfilePoll);
}

void PreviewCoordinator::onRendered()
{
	if (!checkedRenderer.load(std::memory_order_relaxed)) {
		if (gs_get_device_type() != GS_DEVICE_OPENGL) {
			unsupportedRenderer.store(true);
			obs_log(LOG_WARNING, "el renderizador no es OpenGL; previsualizaciones desactivadas");
		}
		checkedRenderer.store(true);
	}
	if (unsupportedRenderer.load(std::memory_order_relaxed)) {
		graphicsCallbacks.fetch_add(1);
		return;
	}

	profile_start(kProfileCallback);

	mainRenderer_.poll();
	verticalRenderer_.poll();

	const uint64_t frameTime = obs_get_video_frame_time();
	const uint64_t frameInterval = obs_get_frame_interval_ns();
	gs_texture_t *target = gs_get_render_target();
	gs_texture_t *mainTexture = obs_get_main_texture();
	const bool isMainMix = target && target == mainTexture;

	if (isMainMix) {
		if (mainRenderer_.lastRenderedFrame() != frameTime && mainRenderer_.wantsFrame(frameTime, frameInterval))
			mainRenderer_.render(mainTexture, frameTime);

		mainRenderer_.releaseIfIdle(frameTime);
		verticalRenderer_.releaseIfIdle(frameTime);

		if (verticalTexture_ && frameTime - verticalSeenAt_ >= kVerticalLostNs)
			forgetVerticalTexture();
	}

	obs_canvas_t *canvas = verticalCanvas.load();
	if (canvas != trackedCanvas_) {
		trackedCanvas_ = canvas;
		forgetVerticalTexture();
		searchingSince_ = 0;
		warnedNotFound_ = false;
	}

	if (isMainMix && canvas && !verticalTexture_ &&
	    verticalShared.requestedSize.load(std::memory_order_relaxed) != 0) {
		if (!searchingSince_)
			searchingSince_ = frameTime;
		if (!warnedNotFound_ && frameTime - searchingSince_ >= kNotFoundWarningNs) {
			warnedNotFound_ = true;
			obs_log(LOG_WARNING, "no se identifica la textura del canvas vertical; ¿tiene vídeo activo?");
		}
	} else if (verticalTexture_) {
		searchingSince_ = 0;
	}

	if (canvas && !isMainMix && target && !obs_canvas_removed(canvas) &&
	    verticalShared.requestedSize.load(std::memory_order_relaxed) != 0) {
		if (relearnVertical.exchange(false))
			forgetVerticalTexture();

		const uint64_t canvasSize = verticalCanvasSize.load();
		if (canvasSize && gs_texture_get_width(target) == PreviewShared::unpackWidth(canvasSize) &&
		    gs_texture_get_height(target) == PreviewShared::unpackHeight(canvasSize) &&
		    isVerticalTexture(target, canvas, frameTime) &&
		    verticalRenderer_.lastRenderedFrame() != frameTime &&
		    verticalRenderer_.wantsFrame(frameTime, frameInterval)) {
			verticalRenderer_.render(target, frameTime);
		}
	}

	profile_end(kProfileCallback);

	/* Permite al hilo principal saber cuándo ningún callback puede seguir
	 * usando un canvas retirado (ver CanvasTracker). */
	graphicsCallbacks.fetch_add(1);
}

void PreviewCoordinator::destroyGraphics()
{
	mainRenderer_.destroy();
	verticalRenderer_.destroy();
	scaler_.destroy();
	if (probeTarget_) {
		gs_texture_destroy(probeTarget_);
		probeTarget_ = nullptr;
	}
	forgetVerticalTexture();
	trackedCanvas_ = nullptr;
}

void PreviewCoordinator::releasePublished()
{
	for (PreviewShared *shared : {&mainShared, &verticalShared}) {
		os_unfair_lock_lock(&shared->lock);
		IOSurfaceRef latest = shared->latest;
		shared->latest = nullptr;
		os_unfair_lock_unlock(&shared->lock);
		if (latest)
			CFRelease(latest);
	}
}

} // namespace op
