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

#include "preview-shared.hpp"

#include <array>
#include <cstdint>

struct gs_texture;
typedef struct __GLsync *GLsync;

namespace nbp {

class GlScaler;

/* Productor de una previsualización. Todos los métodos se ejecutan en el
 * hilo gráfico de OBS con el contexto gráfico activo (dentro de un callback
 * de render) o, al descargar el módulo, dentro de obs_enter_graphics().
 *
 * Por fotograma: escala la textura del lienzo con GlScaler directamente
 * sobre una IOSurface libre del anillo y coloca un fence. En fotogramas
 * posteriores comprueba los fences con timeout 0 y publica la superficie
 * más reciente ya terminada. Nunca espera a la GPU ni al hilo principal. */
class PreviewRenderer {
public:
	PreviewRenderer(PreviewShared &shared, GlScaler &scaler, const char *profileName);
	PreviewRenderer(const PreviewRenderer &) = delete;
	PreviewRenderer &operator=(const PreviewRenderer &) = delete;

	/* ¿Hay que dibujar en este fotograma? (visible y dentro del límite de FPS) */
	bool wantsFrame(uint64_t frameTime, uint64_t frameIntervalNs) const;

	/* Escala `source` (textura 2D de libobs, ya renderizada en este
	 * fotograma) sobre una superficie libre del anillo. */
	void render(gs_texture *source, uint64_t frameTime);

	/* Comprueba fences sin esperar y publica la superficie lista más nueva. */
	void poll();

	/* Libera las superficies si la previsualización lleva un rato oculta. */
	void releaseIfIdle(uint64_t frameTime);

	/* Libera todos los recursos GL e IOSurface. */
	void destroy();

	uint64_t lastRenderedFrame() const { return lastFrameTime_; }

#ifdef NBP_RENDERER_TIMING
	/* Solo para el banco de pruebas: duración de cada paso (ns). */
	struct Timing {
		uint64_t poll = 0, acquire = 0, draw = 0, fence = 0, recreate = 0;
	};
	Timing lastTiming{};
#endif

private:
	static constexpr int kRingSize = 4;

	struct Slot {
		IOSurfaceRef surface = nullptr;
		gs_texture *texture = nullptr;
		unsigned int fbo = 0;
		GLsync fence = nullptr;
		bool flushed = false;
		bool ready = false;
		uint64_t serial = 0;
	};

	bool ensureResources(uint32_t width, uint32_t height);
	Slot *acquireSlot();

	PreviewShared &shared_;
	GlScaler &scaler_;
	const char *profileName_;

	std::array<Slot, kRingSize> slots_{};
	uint32_t width_ = 0;
	uint32_t height_ = 0;
	bool failed_ = false;
	uint64_t failedSize_ = 0;

	uint64_t serial_ = 0;
	uint64_t lastFrameTime_ = 0;
};

} // namespace nbp
