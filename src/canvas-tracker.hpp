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

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

struct calldata;
struct obs_canvas;
class QObject;
class QTimer;

namespace nbp {

/* Localiza un canvas por UUID o por nombre y lo pone a disposición del hilo
 * gráfico. Vive en el hilo principal.
 *
 * Propiedad: la referencia fuerte la tiene siempre este objeto, nunca el
 * hilo gráfico. Si el último obs_canvas_release() ocurriera en el hilo
 * gráfico, dentro de un callback de render (que libobs ejecuta con
 * mixes_mutex tomado), obs_canvas_destroy() volvería a tomar ese mutex y se
 * interbloquearía.
 *
 * Retirada: se publica nullptr y solo se libera la referencia cuando el
 * contador de callbacks del hilo gráfico ha avanzado (todo callback que
 * leyera el puntero anterior ya ha terminado). El hilo gráfico no espera
 * nunca; es el hilo principal quien comprueba el contador. */
class CanvasTracker {
public:
	using StatusFn = std::function<void(bool found)>;

	CanvasTracker(std::atomic<obs_canvas *> &published, std::atomic<uint64_t> &publishedSize,
		      std::atomic<bool> &relearn, std::atomic<uint64_t> &graphicsCallbacks);
	~CanvasTracker();
	CanvasTracker(const CanvasTracker &) = delete;
	CanvasTracker &operator=(const CanvasTracker &) = delete;

	void setTarget(const std::string &name, const std::string &uuid);
	void setStatusCallback(StatusFn callback) { status_ = std::move(callback); }

	void start();

	/* Suelta todo de inmediato. Solo es seguro cuando el callback de render
	 * ya se ha quitado (no puede haber ningún uso en curso). */
	void stopAfterCallbackRemoved();

	const std::string &name() const { return name_; }

private:
	void refresh();
	void acquire(obs_canvas *canvas);
	void retire();
	void releaseRetired(bool force);
	void notify(bool found);
	void publishSize();

	static void onGlobalCanvasSignal(void *param, calldata *data);
	static void onCanvasRemove(void *param, calldata *data);
	static void onCanvasVideoReset(void *param, calldata *data);

	std::atomic<obs_canvas *> &published_;
	std::atomic<uint64_t> &publishedSize_;
	std::atomic<bool> &relearn_;
	std::atomic<uint64_t> &graphicsCallbacks_;

	std::string name_;
	std::string uuid_;
	StatusFn status_;
	int lastStatus_ = -1;

	obs_canvas *canvas_ = nullptr;
	struct Retired {
		obs_canvas *canvas;
		uint64_t safeAfter;
	};
	std::vector<Retired> retired_;

	QObject *context_ = nullptr;
	QTimer *pollTimer_ = nullptr;
	QTimer *releaseTimer_ = nullptr;
	bool started_ = false;
};

} // namespace nbp
