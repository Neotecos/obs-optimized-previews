/* Optimized Previews — GPL-2.0-or-later */
#include "preview-coordinator.hpp"
#include <obs.h>
#include <graphics/graphics.h>
#include <graphics/vec4.h>
#include <util/profiler.h>
#include <plugin-support.h>
#include <algorithm>
#include <cstring>

#ifdef _WIN32
#include <d3d11.h>
#include <wrl/client.h>
#else
#include <epoxy/gl.h>
#endif

namespace op {

struct PortableRenderer::Slot {
	gs_stagesurf_t *surface = nullptr;
	bool pending = false;
	uint64_t frameTime = 0, serial = 0;
#ifdef _WIN32
	Microsoft::WRL::ComPtr<ID3D11Query> fence;
	Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
	bool createFence()
	{
		auto *device = static_cast<ID3D11Device *>(gs_get_device_obj());
		device->GetImmediateContext(&context);
		D3D11_QUERY_DESC desc{D3D11_QUERY_EVENT, 0};
		return SUCCEEDED(device->CreateQuery(&desc, &fence));
	}
	bool submit()
	{
		context->End(fence.Get());
		return true;
	}
	bool ready()
	{
		BOOL done = FALSE;
		return context->GetData(fence.Get(), &done, sizeof(done), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK && done;
	}
#else
	GLsync fence = nullptr;
	bool createFence() { return true; }
	bool submit()
	{
		fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
		return fence != nullptr;
	}
	bool ready()
	{
		const GLenum result = glClientWaitSync(fence, 0, 0);
		if (result != GL_ALREADY_SIGNALED && result != GL_CONDITION_SATISFIED)
			return false;
		glDeleteSync(fence);
		fence = nullptr;
		return true;
	}
#endif
	~Slot()
	{
#ifndef _WIN32
		if (fence)
			glDeleteSync(fence);
#endif
		if (surface)
			gs_stagesurface_destroy(surface);
	}
};

PortableRenderer::PortableRenderer(PreviewShared &shared) : shared_(shared) {}
PortableRenderer::~PortableRenderer() = default;

bool PortableRenderer::ensure(uint32_t width, uint32_t height)
{
	if (target_ && width_ == width && height_ == height)
		return true;
	/* Do not destroy resources while the GPU still uses them during a resize. */
	for (auto &slot : slots_)
		if (slot && slot->pending)
			return false;
	destroy();
	target_ = gs_texrender_create(GS_BGRA, GS_ZS_NONE);
	if (!target_)
		return false;
	for (auto &slot : slots_) {
		slot = std::make_unique<Slot>();
		slot->surface = gs_stagesurface_create(width, height, GS_BGRA);
		if (!slot->surface || !slot->createFence()) {
			destroy();
			return false;
		}
	}
	width_ = width;
	height_ = height;
	return true;
}

void PortableRenderer::render(obs_canvas *canvas, uint32_t sourceWidth, uint32_t sourceHeight, uint64_t frameTime)
{
	const uint64_t requested = shared_.requestedSize.load(std::memory_order_relaxed);
	if (!requested) {
		if (lastFrameTime_ && frameTime - lastFrameTime_ > 10000000000ULL) {
			bool pending = false;
			for (auto &slot : slots_)
				pending |= slot && slot->pending;
			if (!pending)
				destroy();
		}
		return;
	}
	if (!sourceWidth || !sourceHeight || frameTime == lastFrameTime_)
		return;
	const uint32_t fps = shared_.fpsLimit.load(std::memory_order_relaxed);
	if (fps && lastFrameTime_ && frameTime - lastFrameTime_ + obs_get_frame_interval_ns() / 2 < 1000000000ULL / fps)
		return;

	/* Bound readback cost even on HiDPI/4K displays. Never upscale the canvas. */
	const double scale = std::min({1.0, double(PreviewShared::unpackWidth(requested)) / sourceWidth,
				       double(PreviewShared::unpackHeight(requested)) / sourceHeight,
				       1920.0 / sourceWidth, 1080.0 / sourceHeight});
	const uint32_t width = std::max(1u, uint32_t(sourceWidth * scale));
	const uint32_t height = std::max(1u, uint32_t(sourceHeight * scale));
	if (!ensure(width, height))
		return;
	Slot *free = nullptr;
	for (auto &slot : slots_)
		if (!slot->pending) {
			free = slot.get();
			break;
		}
	if (!free) {
		shared_.framesSkippedBusy.fetch_add(1, std::memory_order_relaxed);
		return;
	}

	gs_texrender_reset(target_);
	gs_viewport_push();
	gs_projection_push();
	gs_matrix_push();
	gs_matrix_identity();
	gs_blend_state_push();
	if (gs_texrender_begin(target_, width, height)) {
		struct vec4 black;
		vec4_set(&black, 0, 0, 0, 1);
		gs_clear(GS_CLEAR_COLOR, &black, 0, 0);
		gs_ortho(0, float(sourceWidth), 0, float(sourceHeight), -100, 100);
		/* These public APIs draw the already composed canvas, never its scenes.
		 * The selected canvas is sampled once per main mix, with up to one
		 * extra frame of latency when it follows the main mix in OBS. */
		if (canvas)
			obs_render_canvas_texture_src_color_only(canvas);
		else
			obs_render_main_texture_src_color_only();
		gs_texrender_end(target_);
		gs_stage_texture(free->surface, gs_texrender_get_texture(target_));
		free->pending = free->submit();
		free->frameTime = frameTime;
		free->serial = ++serial_;
		lastFrameTime_ = frameTime;
	}
	gs_blend_state_pop();
	gs_matrix_pop();
	gs_projection_pop();
	gs_viewport_pop();
}

void PortableRenderer::poll()
{
	Slot *newest = nullptr;
	for (auto &slot : slots_)
		if (slot && slot->pending && slot->ready()) {
			slot->pending = false;
			if (slot->serial > publishedSerial_ && (!newest || slot->serial > newest->serial))
				newest = slot.get();
		}
	if (!newest)
		return;
	/* Acquire the mailbox before allocating or mapping. Never wait for Qt. */
	std::unique_lock lock(shared_.lock, std::try_to_lock);
	if (!lock.owns_lock())
		return;
	uint8_t *data = nullptr;
	uint32_t stride = 0;
	/* The fence covers the staging copy; mapping cannot wait on GPU work. */
	if (!gs_stagesurface_map(newest->surface, &data, &stride))
		return;
	QImage image(int(width_), int(height_), QImage::Format_RGB32);
	if (!image.isNull()) {
		for (uint32_t y = 0; y < height_; ++y)
			std::memcpy(image.scanLine(int(y)), data + size_t(y) * stride, size_t(width_) * 4);
	}
	gs_stagesurface_unmap(newest->surface);
	if (image.isNull())
		return;
	shared_.latest = std::move(image);
	shared_.latestFrameTime = newest->frameTime;
	++shared_.latestSerial;
	publishedSerial_ = newest->serial;
	shared_.framesPublished.fetch_add(1, std::memory_order_relaxed);
}

void PortableRenderer::destroy()
{
	for (auto &slot : slots_)
		slot.reset();
	if (target_)
		gs_texrender_destroy(target_);
	target_ = nullptr;
	width_ = height_ = 0;
}

PreviewCoordinator::PreviewCoordinator() : mainRenderer_(mainShared), verticalRenderer_(verticalShared) {}

void PreviewCoordinator::onBeforeRender()
{
	if (!checkedRenderer.load() || unsupportedRenderer.load())
		return;
	profile_start("op_poll");
	mainRenderer_.poll();
	verticalRenderer_.poll();
	profile_end("op_poll");
}

void PreviewCoordinator::onRendered()
{
	if (!checkedRenderer.load()) {
#ifdef _WIN32
		unsupportedRenderer.store(gs_get_device_type() != GS_DEVICE_DIRECT3D_11);
#else
		unsupportedRenderer.store(gs_get_device_type() != GS_DEVICE_OPENGL || !epoxy_has_gl_extension("GL_ARB_sync"));
#endif
		checkedRenderer.store(true);
		if (unsupportedRenderer.load())
			obs_log(LOG_WARNING, "unsupported graphics renderer; previews disabled");
	}
	if (!unsupportedRenderer.load()) {
		onBeforeRender();
		const uint64_t now = obs_get_video_frame_time();
		/* Never sample the selected canvas while its own render target is bound. */
		if (now != lastFrameTime_ && gs_get_render_target() == obs_get_main_texture() && obs_get_main_texture()) {
			lastFrameTime_ = now;
			profile_start("op_rendered_callback");
			struct obs_video_info info;
			if (obs_get_video_info(&info))
				mainRenderer_.render(nullptr, info.base_width, info.base_height, now);
			auto *canvas = verticalCanvas.load();
			const uint64_t size = verticalCanvasSize.load();
			if (canvas && size && !obs_canvas_removed(canvas))
				verticalRenderer_.render(canvas, PreviewShared::unpackWidth(size), PreviewShared::unpackHeight(size), now);
			else
				verticalRenderer_.destroy();
			profile_end("op_rendered_callback");
		}
	}
	graphicsCallbacks.fetch_add(1);
}

void PreviewCoordinator::destroyGraphics()
{
	mainRenderer_.destroy();
	verticalRenderer_.destroy();
}

void PreviewCoordinator::releasePublished()
{
	for (auto *shared : {&mainShared, &verticalShared}) {
		std::lock_guard lock(shared->lock);
		shared->latest = {};
	}
}
} // namespace op
