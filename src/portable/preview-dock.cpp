/* Optimized Previews — GPL-2.0-or-later */
#include "../preview-dock.hpp"
#include <obs-module.h>
#include <util/platform.h>
#include <QActionGroup>
#include <QContextMenuEvent>
#include <QMenu>
#include <QPainter>
#include <QTimer>
#include <algorithm>

namespace op {
PreviewDock::PreviewDock(PreviewShared &shared, QWidget *parent) : QWidget(parent), shared_(shared)
{
	setMinimumSize(kMinimumSize);
	setAttribute(Qt::WA_OpaquePaintEvent);
	auto *timer = new QTimer(this);
	timer->setTimerType(Qt::PreciseTimer);
	timer->setInterval(8);
	connect(timer, &QTimer::timeout, this, [this]() { step(); });
	timer->start();
}
PreviewDock::~PreviewDock() { shutdown(); }
void PreviewDock::shutdown()
{
	if (shutdown_)
		return;
	shutdown_ = true;
	shared_.requestedSize.store(0);
	image_ = {};
}
void PreviewDock::setMessage(const QString &message)
{
	message_ = message;
	if (!message.isEmpty()) {
		image_ = {};
		shared_.requestedSize.store(0);
	}
	update();
}
bool PreviewDock::event(QEvent *event) { return QWidget::event(event); }
void PreviewDock::showEvent(QShowEvent *event)
{
	QWidget::showEvent(event);
	step();
}
void PreviewDock::hideEvent(QHideEvent *event)
{
	if (!shutdown_)
		shared_.requestedSize.store(0);
	QWidget::hideEvent(event);
}
void PreviewDock::step()
{
	if (shutdown_)
		return;
	if (!isVisible() || !message_.isEmpty() || width() <= 0 || height() <= 0) {
		shared_.requestedSize.store(0);
		return;
	}
	const uint64_t now = os_gettime_ns();
	const qreal scale = devicePixelRatioF();
	const uint64_t size = PreviewShared::packSize(uint32_t(width() * scale), uint32_t(height() * scale));
	if (size != pendingSize_) {
		pendingSize_ = size;
		pendingSince_ = now;
	}
	if (!shared_.requestedSize.load() || now - pendingSince_ >= 150000000ULL)
		shared_.requestedSize.store(size);
	uint64_t serial, frameTime;
	{
		std::unique_lock lock(shared_.lock, std::try_to_lock);
		if (!lock.owns_lock() || shared_.latestSerial == seenSerial_ || shared_.latest.isNull())
			return;
		serial = shared_.latestSerial;
		frameTime = shared_.latestFrameTime;
		image_ = shared_.latest;
	}
	if (lastPresentTime_ && now - lastPresentTime_ < 250000000ULL) {
		if (frameTime && now > frameTime)
			shared_.recordLatency(now - frameTime);
		if (seenSerial_ && serial > seenSerial_ + 1)
			shared_.framesSuperseded.fetch_add(serial - seenSerial_ - 1);
		const uint32_t limit = shared_.fpsLimit.load();
		const uint64_t interval = obs_get_frame_interval_ns();
		const uint64_t expected = limit ? std::max<uint64_t>(interval, 1000000000ULL / limit) : interval;
		if (lastFrameTime_ && frameTime > lastFrameTime_ && (frameTime - lastFrameTime_) * 2 > expected * 3)
			shared_.presentGaps.fetch_add(1);
	}
	seenSerial_ = serial;
	lastFrameTime_ = frameTime;
	lastPresentTime_ = now;
	shared_.framesPresented.fetch_add(1);
	update();
}
void PreviewDock::paintEvent(QPaintEvent *)
{
	QPainter painter(this);
	painter.fillRect(rect(), Qt::black);
	if (!message_.isEmpty()) {
		painter.setPen(palette().color(QPalette::Text));
		painter.drawText(rect().adjusted(12, 12, -12, -12), Qt::AlignCenter | Qt::TextWordWrap, message_);
	} else if (!image_.isNull()) {
		const QSize size = image_.size().scaled(this->size(), Qt::KeepAspectRatio);
		const QRect target(QPoint((width() - size.width()) / 2, (height() - size.height()) / 2), size);
		painter.setRenderHint(QPainter::SmoothPixmapTransform);
		painter.drawImage(target, image_);
	}
}

void PreviewDock::contextMenuEvent(QContextMenuEvent *event)
{
	/* Tras el cierre el estado compartido puede haberse liberado. */
	if (shutdown_)
		return;

	QMenu menu(this);
	QMenu *fpsMenu = menu.addMenu(QString::fromUtf8(obs_module_text("Menu.FpsLimit")));
	auto *group = new QActionGroup(fpsMenu);

	const unsigned int current = shared_.fpsLimit.load(std::memory_order_relaxed);
	const struct {
		unsigned int fps;
		const char *label;
	} options[] = {
		{0, "Menu.FpsLimit.None"},
		{60, "Menu.FpsLimit.60"},
		{30, "Menu.FpsLimit.30"},
		{20, "Menu.FpsLimit.20"},
	};

	for (const auto &option : options) {
		QAction *action = fpsMenu->addAction(QString::fromUtf8(obs_module_text(option.label)));
		action->setCheckable(true);
		action->setChecked(option.fps == current);
		group->addAction(action);
		const unsigned int fps = option.fps;
		connect(action, &QAction::triggered, this, [this, fps]() {
			shared_.fpsLimit.store(fps, std::memory_order_relaxed);
			emit fpsLimitSelected(fps);
		});
	}

	if (menuExtender_)
		menuExtender_(&menu);

	menu.exec(event->globalPos());
}

} // namespace op
