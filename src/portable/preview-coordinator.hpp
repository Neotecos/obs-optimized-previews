/* Optimized Previews — GPL-2.0-or-later */
#pragma once

#include "../preview-shared.hpp"
#include <array>
#include <memory>

struct obs_canvas;
struct gs_texture;
struct gs_stage_surface;
struct gs_texture_render;

namespace op {

/* Only the OBS graphics thread touches GPU resources. Qt receives immutable
 * images through a try-lock mailbox; GPU completion is polled with timeout 0. */
class PortableRenderer {
public:
	explicit PortableRenderer(PreviewShared &shared);
	~PortableRenderer();
	void render(obs_canvas *canvas, uint32_t sourceWidth, uint32_t sourceHeight, uint64_t frameTime);
	void poll();
	void destroy();

private:
	struct Slot;
	PreviewShared &shared_;
	std::array<std::unique_ptr<Slot>, 3> slots_;
	gs_texture_render *target_ = nullptr;
	uint32_t width_ = 0, height_ = 0;
	uint64_t lastFrameTime_ = 0;
	uint64_t serial_ = 0, publishedSerial_ = 0;
	bool ensure(uint32_t width, uint32_t height);
};

class PreviewCoordinator {
public:
	PreviewCoordinator();
	void onRendered();
	void onBeforeRender();
	void destroyGraphics();
	void releasePublished();

	PreviewShared mainShared, verticalShared;
	std::atomic<obs_canvas *> verticalCanvas{nullptr};
	std::atomic<uint64_t> verticalCanvasSize{0};
	std::atomic<bool> relearnVertical{true};
	std::atomic<uint64_t> graphicsCallbacks{0};
	std::atomic<bool> checkedRenderer{false}, unsupportedRenderer{false};

private:
	PortableRenderer mainRenderer_, verticalRenderer_;
	uint64_t lastFrameTime_ = 0;
};
} // namespace op
