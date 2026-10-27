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

#include "canvas-tracker.hpp"

#include <obs.h>
#include <plugin-support.h>

#include <QObject>
#include <QPointer>
#include <QTimer>

namespace nbp {

namespace {

/* Búsqueda periódica por si el canvas aparece sin que llegue una señal. */
constexpr int kPollIntervalMs = 2000;
constexpr int kReleaseIntervalMs = 50;

} // namespace

CanvasTracker::CanvasTracker(std::atomic<obs_canvas *> &published, std::atomic<uint64_t> &publishedSize,
			     std::atomic<bool> &relearn, std::atomic<uint64_t> &graphicsCallbacks)
	: published_(published),
	  publishedSize_(publishedSize),
	  relearn_(relearn),
	  graphicsCallbacks_(graphicsCallbacks)
{
	context_ = new QObject();
	pollTimer_ = new QTimer(context_);
	pollTimer_->setInterval(kPollIntervalMs);
	QObject::connect(pollTimer_, &QTimer::timeout, context_, [this]() { refresh(); });

	releaseTimer_ = new QTimer(context_);
	releaseTimer_->setInterval(kReleaseIntervalMs);
	QObject::connect(releaseTimer_, &QTimer::timeout, context_, [this]() { releaseRetired(false); });
}

CanvasTracker::~CanvasTracker()
{
	stopAfterCallbackRemoved();
	delete context_;
}

void CanvasTracker::setTarget(const std::string &name, const std::string &uuid)
{
	if (name == name_ && uuid == uuid_)
		return;
	name_ = name;
	uuid_ = uuid;
	if (started_) {
		retire();
		refresh();
	}
}

void CanvasTracker::start()
{
	if (started_)
		return;
	started_ = true;

	signal_handler_t *handler = obs_get_signal_handler();
	signal_handler_connect(handler, "canvas_create", onGlobalCanvasSignal, this);
	signal_handler_connect(handler, "canvas_remove", onGlobalCanvasSignal, this);
	signal_handler_connect(handler, "canvas_rename", onGlobalCanvasSignal, this);

	pollTimer_->start();
	refresh();
}

void CanvasTracker::stopAfterCallbackRemoved()
{
	if (started_) {
		signal_handler_t *handler = obs_get_signal_handler();
		signal_handler_disconnect(handler, "canvas_create", onGlobalCanvasSignal, this);
		signal_handler_disconnect(handler, "canvas_remove", onGlobalCanvasSignal, this);
		signal_handler_disconnect(handler, "canvas_rename", onGlobalCanvasSignal, this);
		started_ = false;
	}

	pollTimer_->stop();
	retire();
	releaseRetired(true);
}

void CanvasTracker::refresh()
{
	if (!started_)
		return;

	if (canvas_ && (obs_canvas_removed(canvas_) || (!uuid_.empty() && uuid_ != obs_canvas_get_uuid(canvas_)) ||
			(uuid_.empty() && name_ != obs_canvas_get_name(canvas_))))
		retire();

	if (!canvas_) {
		obs_canvas_t *found = nullptr;
		if (!uuid_.empty())
			found = obs_get_canvas_by_uuid(uuid_.c_str());
		if (!found && !name_.empty())
			found = obs_get_canvas_by_name(name_.c_str());
		if (found && obs_canvas_removed(found)) {
			obs_canvas_release(found);
			found = nullptr;
		}
		if (found)
			acquire(found);
	}

	notify(canvas_ != nullptr);
}

void CanvasTracker::acquire(obs_canvas_t *canvas)
{
	canvas_ = canvas;

	signal_handler_t *handler = obs_canvas_get_signal_handler(canvas_);
	signal_handler_connect(handler, "remove", onCanvasRemove, this);
	signal_handler_connect(handler, "video_reset", onCanvasVideoReset, this);

	publishSize();
	relearn_.store(true);
	published_.store(canvas_);

	obs_log(LOG_INFO, "canvas «%s» (%s) localizado", obs_canvas_get_name(canvas_), obs_canvas_get_uuid(canvas_));
}

void CanvasTracker::retire()
{
	if (!canvas_)
		return;

	published_.store(nullptr);
	publishedSize_.store(0);

	signal_handler_t *handler = obs_canvas_get_signal_handler(canvas_);
	signal_handler_disconnect(handler, "remove", onCanvasRemove, this);
	signal_handler_disconnect(handler, "video_reset", onCanvasVideoReset, this);

	/* Un callback que leyó el puntero antes del store termina incrementando
	 * el contador; a partir de ahí ninguno puede verlo. */
	retired_.push_back({canvas_, graphicsCallbacks_.load() + 1});
	canvas_ = nullptr;
	releaseTimer_->start();

	obs_log(LOG_INFO, "canvas vertical retirado");
}

void CanvasTracker::releaseRetired(bool force)
{
	const uint64_t callbacks = graphicsCallbacks_.load();
	for (auto it = retired_.begin(); it != retired_.end();) {
		if (force || callbacks >= it->safeAfter) {
			obs_canvas_release(it->canvas);
			it = retired_.erase(it);
		} else {
			++it;
		}
	}
	if (retired_.empty())
		releaseTimer_->stop();
}

/* Solo desde el hilo que modifica el canvas (el principal o el que emite
 * video_reset, justo después del cambio). */
void CanvasTracker::publishSize()
{
	struct obs_video_info ovi;
	if (canvas_ && obs_canvas_get_video_info(canvas_, &ovi))
		publishedSize_.store((uint64_t(ovi.base_width) << 32) | uint64_t(ovi.base_height));
	else
		publishedSize_.store(0);
}

void CanvasTracker::notify(bool found)
{
	if (lastStatus_ == int(found))
		return;
	lastStatus_ = int(found);
	if (status_)
		status_(found);
}

void CanvasTracker::onGlobalCanvasSignal(void *param, calldata *)
{
	/* Puede llegar desde cualquier hilo: se reprograma en el principal. */
	auto *self = static_cast<CanvasTracker *>(param);
	QMetaObject::invokeMethod(self->context_, [self]() { self->refresh(); }, Qt::QueuedConnection);
}

void CanvasTracker::onCanvasRemove(void *param, calldata *data)
{
	onGlobalCanvasSignal(param, data);
}

void CanvasTracker::onCanvasVideoReset(void *param, calldata *)
{
	/* Se emite en el hilo que ha hecho obs_canvas_reset_video(), con la
	 * mezcla nueva ya asignada. Su textura es otra: hay que verificarla. */
	auto *self = static_cast<CanvasTracker *>(param);
	self->publishSize();
	self->relearn_.store(true);
}

} // namespace nbp
