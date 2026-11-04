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

#pragma once

#include <atomic>
#include <cstdint>

#ifdef __APPLE__
#include <IOSurface/IOSurfaceRef.h>
#include <os/lock.h>
#else
#include <QImage>
#include <mutex>
#endif

namespace op {

/* Estado que comparten el hilo gráfico de OBS (productor) y el hilo
 * principal (consumidor) para una previsualización.
 *
 * Reglas:
 * - El hilo gráfico nunca espera: solo usa os_unfair_lock_trylock() y, si
 *   no consigue el cerrojo, lo reintenta en el siguiente fotograma.
 * - El hilo principal toma el cerrojo durante unas pocas instrucciones
 *   (leer y retener la última superficie) y nunca toca el contexto gráfico. */
struct PreviewShared {
	/* Hilo principal -> hilo gráfico. */

	/* Tamaño en píxeles del área visible del dock, empaquetado como
	 * (ancho << 32) | alto. 0 significa «no dibujar» (oculto o sin tamaño). */
	std::atomic<uint64_t> requestedSize{0};
	/* Límite de FPS de esta previsualización; 0 = el de OBS. */
	std::atomic<uint32_t> fpsLimit{0};

	/* Hilo gráfico -> hilo principal, protegido por `lock`. */
#ifdef __APPLE__
	os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
	/* Última superficie completa (su fence ya está señalado). Retenida. */
	IOSurfaceRef latest = nullptr;
	/* Se incrementa cada vez que se publica una superficie. */
	uint64_t latestSerial = 0;
	/* Tiempo de vídeo (obs_get_video_frame_time) del fotograma publicado. */
	uint64_t latestFrameTime = 0;
	/* Superficie que el hilo principal ha puesto en su CALayer (solo como
	 * identidad, sin retener): el hilo gráfico no la reutiliza. */
	IOSurfaceRef displayed = nullptr;

#else
	std::mutex lock;
	QImage latest;
	uint64_t latestSerial = 0;
	uint64_t latestFrameTime = 0;
#endif

	/* Estadísticas (solo informativas). */
	std::atomic<uint64_t> framesPublished{0};
	std::atomic<uint64_t> framesSkippedBusy{0};
	/* Desde el tiempo de vídeo del fotograma hasta que el hilo principal lo
	 * entrega a Core Animation. */
	std::atomic<uint64_t> latencySumNs{0};
	std::atomic<uint64_t> latencyCount{0};
	std::atomic<uint64_t> latencyMaxNs{0};
	/* Cadencia vista por el hilo principal: fotogramas publicados que nunca
	 * llegaron a la capa (los sustituyó otro más nuevo entre dos ticks del
	 * display link) y huecos entre imágenes nuevas de más de 1,5 fotogramas. */
	std::atomic<uint64_t> framesSuperseded{0};
	std::atomic<uint64_t> presentGaps{0};
	std::atomic<uint64_t> framesPresented{0};

	void recordLatency(uint64_t ns)
	{
		latencySumNs.fetch_add(ns, std::memory_order_relaxed);
		latencyCount.fetch_add(1, std::memory_order_relaxed);
		uint64_t max = latencyMaxNs.load(std::memory_order_relaxed);
		while (ns > max && !latencyMaxNs.compare_exchange_weak(max, ns, std::memory_order_relaxed))
			;
	}

	static constexpr uint64_t packSize(uint32_t width, uint32_t height)
	{
		return (uint64_t(width) << 32) | uint64_t(height);
	}
	static constexpr uint32_t unpackWidth(uint64_t packed) { return uint32_t(packed >> 32); }
	static constexpr uint32_t unpackHeight(uint64_t packed) { return uint32_t(packed & 0xffffffffu); }
};

} // namespace op
