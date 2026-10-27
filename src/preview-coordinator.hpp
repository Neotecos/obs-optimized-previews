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

#pragma once

#include "gl-scaler.hpp"
#include "preview-renderer.hpp"
#include "preview-shared.hpp"

#include <atomic>
#include <cstdint>
#include <vector>

struct gs_texture;
struct obs_canvas;

namespace nbp {

/* Trabajo del hilo gráfico para las dos previsualizaciones. onRendered()
 * se registra con obs_add_main_rendered_callback(): libobs lo llama al
 * terminar CADA mezcla de vídeo (lienzo principal, canvas adicionales y
 * mezclas de codificadores multipista), con el render target todavía
 * apuntando a la textura recién compuesta. Cada previsualización se dibuja
 * una sola vez por fotograma, en el callback de su propia mezcla. */
class PreviewCoordinator {
public:
	PreviewCoordinator();
	PreviewCoordinator(const PreviewCoordinator &) = delete;
	PreviewCoordinator &operator=(const PreviewCoordinator &) = delete;

	/* Hilo gráfico, desde obs_add_main_rendered_callback(). */
	void onRendered();

	/* Hilo gráfico, desde obs_add_main_render_callback(): al empezar cada
	 * mezcla solo se sondean los fences, para publicar el fotograma
	 * anterior sin esperar a que termine la composición del actual. */
	void onBeforeRender();

	/* Libera los recursos GL (dentro de obs_enter_graphics). */
	void destroyGraphics();

	/* Suelta las últimas superficies publicadas (tras destroyGraphics). */
	void releasePublished();

	PreviewShared mainShared;
	PreviewShared verticalShared;

	/* Canvas vertical publicado por el hilo principal (CanvasTracker). La
	 * referencia fuerte la conserva siempre el hilo principal. */
	std::atomic<obs_canvas *> verticalCanvas{nullptr};
	/* Pide volver a verificar la textura del canvas (video_reset). */
	std::atomic<bool> relearnVertical{true};
	/* Callbacks terminados; ver CanvasTracker. */
	std::atomic<uint64_t> graphicsCallbacks{0};

	std::atomic<bool> checkedRenderer{false};
	std::atomic<bool> unsupportedRenderer{false};

private:
	bool isVerticalTexture(gs_texture *candidate, obs_canvas *canvas, uint64_t frameTime);
	bool verifyCanvasTexture(gs_texture *candidate, obs_canvas *canvas);
	void forgetVerticalTexture();

	GlScaler scaler_;
	PreviewRenderer mainRenderer_;
	PreviewRenderer verticalRenderer_;

	/* Solo hilo gráfico. */
	obs_canvas *trackedCanvas_ = nullptr;
	gs_texture *verticalTexture_ = nullptr; /* verificada; solo para comparar */
	uint64_t verifiedAt_ = 0;
	uint64_t verticalSeenAt_ = 0;
	std::vector<gs_texture *> rejected_;
	uint64_t rejectedSince_ = 0;
	uint64_t searchingSince_ = 0;
	bool warnedNotFound_ = false;
	gs_texture *probeTarget_ = nullptr;
};

} // namespace nbp
