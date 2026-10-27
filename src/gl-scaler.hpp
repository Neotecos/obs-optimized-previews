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

#include <cstdint>

namespace nbp {

/* Escalado de una textura GL_TEXTURE_2D de libobs a un framebuffer propio
 * con una sola pasada de un shader mínimo y llamadas GL directas.
 *
 * Medido en el hilo gráfico de OBS 33 (OpenGL sobre Metal, M4 Max), un
 * dibujo así cuesta en CPU unas tres veces menos que glBlitFramebuffer o
 * que dibujar con libobs en un render target intermedio (tests/copy-probe).
 *
 * Guarda y restaura exactamente todo el estado GL que toca, de modo que el
 * seguimiento interno de estado de libobs-opengl sigue siendo válido.
 * Solo se usa en el hilo gráfico con el contexto activo. */
class GlScaler {
public:
	GlScaler() = default;
	GlScaler(const GlScaler &) = delete;
	GlScaler &operator=(const GlScaler &) = delete;

	/* Crea programa, VAO y sampler la primera vez. */
	bool ensure();
	void destroy();

	/* Dibuja `sourceTexture` (sRGB) ocupando todo `framebuffer`
	 * (width×height), con filtrado bilineal en espacio lineal y 4 muestras
	 * cuando la reducción es de 2:1 o mayor. Alfa de salida = 1. */
	void draw(unsigned int sourceTexture, uint32_t sourceWidth, uint32_t sourceHeight, unsigned int framebuffer,
		  uint32_t width, uint32_t height);

private:
	unsigned int program_ = 0;
	unsigned int vao_ = 0;
	unsigned int sampler_ = 0;
	int invOutputSizeLocation_ = -1;
	int tapOffsetLocation_ = -1;
	bool failed_ = false;
};

} // namespace nbp
