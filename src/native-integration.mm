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

#include "native-integration.hpp"

#include "preview-dock.hpp"

#include <obs-module.h>
#include <obs-frontend-api.h>
#include <obs-hotkey.h>
#include <plugin-support.h>

#include <QAction>
#include <QBoxLayout>
#include <QContextMenuEvent>
#include <QDateTime>
#include <QDockWidget>
#include <QFrame>
#include <QLabel>
#include <QMainWindow>
#include <QMenu>
#include <QMouseEvent>
#include <QPushButton>
#include <QScreen>
#include <QTimer>

#include <cstring>

namespace nbp {

namespace {

/* Identificadores internos de OBS 33 (OBSBasic.ui) y Vertical Canvas 1.6.x. */
const char *const kObsPreviewName = "preview";
const char *const kObsPreviewClass = "OBSBasicPreview";
const char *const kObsDisabledName = "previewDisabledWidget";
const char *const kVerticalDockName = "VerticalCanvasDock";
const char *const kVerticalDockClass = "CanvasDock";
const char *const kVerticalShowHotkey = "VerticalCanvasDockShowPreview";
const char *const kVerticalHideHotkey = "VerticalCanvasDockHidePreview";

/* Reintentos para encontrar los widgets de Vertical Canvas, que puede crear
 * o recrear su dock después de cargar OBS. */
constexpr int kRetryIntervalMs = 2000;
/* Tiempo máximo entre el clic derecho y la aparición del menú nativo. */
constexpr qint64 kArmWindowMs = 2000;

QString text(const char *key)
{
	return QString::fromUtf8(obs_module_text(key));
}

obs_hotkey_id findHotkey(const char *name)
{
	struct Search {
		const char *name;
		obs_hotkey_id id;
	} search{name, OBS_INVALID_HOTKEY_ID};

	obs_enum_hotkeys(
		[](void *data, obs_hotkey_id id, obs_hotkey_t *key) {
			auto *s = static_cast<Search *>(data);
			const char *keyName = obs_hotkey_get_name(key);
			if (keyName && strcmp(keyName, s->name) == 0) {
				s->id = id;
				return false;
			}
			return true;
		},
		&search);
	return search.id;
}

/* Igual que obs-websocket (TriggerHotkeyByName): libobs llama al callback del
 * atajo en este hilo. El frontend de OBS activa este enrutado. */
bool triggerHotkey(const char *name)
{
	const obs_hotkey_id id = findHotkey(name);
	if (id == OBS_INVALID_HOTKEY_ID)
		return false;
	obs_hotkey_trigger_routed_callback(id, true);
	obs_hotkey_trigger_routed_callback(id, false);
	return true;
}

bool isClass(const QObject *object, const char *className)
{
	return object && strcmp(object->metaObject()->className(), className) == 0;
}

/* Mantiene el menú dentro de la pantalla tras añadirle entradas. */
void keepOnScreen(QMenu *menu)
{
	QScreen *screen = menu->screen();
	if (!screen)
		return;
	const QRect available = screen->availableGeometry();
	QRect geometry = menu->geometry();
	if (geometry.bottom() > available.bottom())
		geometry.moveBottom(available.bottom());
	if (geometry.right() > available.right())
		geometry.moveRight(available.right());
	menu->move(geometry.topLeft());
}

} // namespace

NativeIntegration::NativeIntegration(QMainWindow *mainWindow, StateFn onStateChanged)
	: mainWindow_(mainWindow),
	  onStateChanged_(std::move(onStateChanged))
{
	retryTimer_ = new QTimer(this);
	retryTimer_->setInterval(kRetryIntervalMs);
	connect(retryTimer_, &QTimer::timeout, this, [this]() {
		for (int t = 0; t < TargetCount; t++) {
			Slot &slot = slots_[t];
			if (!slot.disabledWidget)
				slot.embedded = false;
			if (slot.enabled && !slot.embedded && locate(Target(t)))
				apply(Target(t));
			else if (!slot.nativePreview)
				locate(Target(t));
		}
	});
}

NativeIntegration::~NativeIntegration()
{
	shutdown();
}

void NativeIntegration::setHome(Target target, QWidget *home, ViewFactory factory)
{
	Slot &slot = slots_[target];
	slot.home = home;
	slot.factory = std::move(factory);
	createView(target);
}

PreviewDock *NativeIntegration::view(Target target) const
{
	return slots_[target].view.data();
}

void NativeIntegration::createView(Target target)
{
	Slot &slot = slots_[target];
	if (!slot.home || !slot.factory || stopped_)
		return;

	PreviewDock *view = slot.factory();
	slot.view = view;
	slot.embedded = false;
	if (auto *layout = qobject_cast<QBoxLayout *>(slot.home->layout()))
		layout->insertWidget(0, view, 1);
	if (slot.placeholder)
		slot.placeholder->hide();

	/* Si el widget nativo que la aloja se destruye, la previsualización se
	 * destruye con él: se crea otra en su dock y se vuelve a integrar. */
	connect(view, &QObject::destroyed, this, [this, target]() {
		if (stopped_)
			return;
		QTimer::singleShot(0, this, [this, target]() {
			if (!slots_[target].view)
				createView(target);
		});
	});
}

void NativeIntegration::start(bool mainEnabled, bool verticalEnabled)
{
	if (started_ || stopped_)
		return;
	started_ = true;

	slots_[Main].enabled = mainEnabled;
	slots_[Vertical].enabled = verticalEnabled;

	for (int t = 0; t < TargetCount; t++) {
		if (locate(Target(t)))
			apply(Target(t));
	}
	retryTimer_->start();
}

void NativeIntegration::shutdown()
{
	if (stopped_)
		return;
	stopped_ = true;
	retryTimer_->stop();
	disarm();
	for (Slot &slot : slots_) {
		for (QWidget *widget : {slot.nativePreview.data(), slot.disabledWidget.data()}) {
			if (widget)
				widget->removeEventFilter(this);
		}
	}
}

bool NativeIntegration::locate(Target target)
{
	Slot &slot = slots_[target];
	if (slot.nativePreview && slot.disabledWidget && slot.menuParent)
		return true;
	if (!mainWindow_)
		return false;

	const bool found = target == Main ? locateMain(slot) : locateVertical(slot);
	if (!found)
		return false;

	slot.nativePreview->installEventFilter(this);
	slot.disabledWidget->installEventFilter(this);
	obs_log(LOG_INFO, "previsualización nativa %s localizada", target == Main ? "principal" : "vertical");
	return true;
}

bool NativeIntegration::locateMain(Slot &slot)
{
	QWidget *preview = nullptr;
	for (QWidget *candidate : mainWindow_->findChildren<QWidget *>(kObsPreviewName)) {
		if (isClass(candidate, kObsPreviewClass)) {
			preview = candidate;
			break;
		}
	}
	/* Vertical Canvas también tiene un widget «preview»: si no se reconoce
	 * la clase, se busca solo en el widget central. */
	if (!preview && mainWindow_->centralWidget())
		preview = mainWindow_->centralWidget()->findChild<QWidget *>(kObsPreviewName);

	auto *disabled = mainWindow_->findChild<QFrame *>(kObsDisabledName);
	if (!preview || !disabled)
		return false;

	slot.nativePreview = preview;
	slot.disabledWidget = disabled;
	slot.menuParent = mainWindow_.data();
	return true;
}

bool NativeIntegration::locateVertical(Slot &slot)
{
	QWidget *canvasDock = nullptr;
	if (auto *dock = mainWindow_->findChild<QDockWidget *>(kVerticalDockName))
		canvasDock = dock->widget();
	if (!isClass(canvasDock, kVerticalDockClass)) {
		canvasDock = nullptr;
		for (QWidget *candidate : mainWindow_->findChildren<QFrame *>()) {
			if (isClass(candidate, kVerticalDockClass)) {
				canvasDock = candidate;
				break;
			}
		}
	}
	if (!canvasDock)
		return false;

	auto *preview = canvasDock->findChild<QWidget *>(kObsPreviewName);

	/* El hueco de «preview desactivada» de Vertical Canvas es un QFrame sin
	 * nombre con el botón «Habilitar previsualización». */
	QString enableText = QString::fromUtf8(obs_frontend_get_locale_string("Basic.Main.PreviewConextMenu.Enable"));
	enableText.remove('&');
	QWidget *disabled = nullptr;
	for (QFrame *frame : canvasDock->findChildren<QFrame *>(QString(), Qt::FindDirectChildrenOnly)) {
		if (frame == preview)
			continue;
		for (QPushButton *button : frame->findChildren<QPushButton *>(QString(), Qt::FindDirectChildrenOnly)) {
			if (button->text().remove('&') == enableText) {
				disabled = frame;
				break;
			}
		}
		if (disabled)
			break;
	}

	if (!preview || !disabled)
		return false;

	slot.nativePreview = preview;
	slot.disabledWidget = disabled;
	slot.menuParent = canvasDock;
	return true;
}

bool NativeIntegration::available(Target target) const
{
	const Slot &slot = slots_[target];
	if (!slot.nativePreview || !slot.disabledWidget || !slot.view)
		return false;
	/* En modo estudio OBS no permite desactivar su previsualización. */
	if (target == Main && obs_frontend_preview_program_mode_active())
		return false;
	return true;
}

bool NativeIntegration::setNativeEnabled(Target target, bool enable)
{
	Slot &slot = slots_[target];
	if (target == Main) {
		obs_frontend_set_preview_enabled(enable);
	} else if (!triggerHotkey(enable ? kVerticalShowHotkey : kVerticalHideHotkey) && enable) {
		/* Sin el atajo, al menos se puede reactivar con su propio botón. */
		if (slot.disabledWidget) {
			if (auto *button = slot.disabledWidget->findChild<QPushButton *>())
				button->click();
		}
	}

	/* Estado real: el hueco de «desactivada» está oculto si la nativa está activa. */
	return slot.disabledWidget && slot.disabledWidget->isHidden() == enable;
}

void NativeIntegration::apply(Target target)
{
	Slot &slot = slots_[target];
	if (slot.enabled) {
		if (slot.embedded || !available(target))
			return;
		if (!setNativeEnabled(target, false)) {
			obs_log(LOG_WARNING, "no se pudo desactivar la previsualización nativa %s",
				target == Main ? "principal" : "vertical");
			return;
		}
		embed(target);
	} else if (slot.embedded) {
		unembed(target);
		setNativeEnabled(target, true);
	}
}

void NativeIntegration::embed(Target target)
{
	Slot &slot = slots_[target];
	if (!slot.view || !slot.disabledWidget)
		return;

	/* Se superpone a todo el hueco sin tocar su layout; el tamaño mínimo
	 * del dock no debe impedir que encaje en un hueco más pequeño. */
	slot.view->setMinimumSize(0, 0);
	slot.view->setParent(slot.disabledWidget);
	slot.view->setGeometry(slot.disabledWidget->rect());
	slot.view->show();
	slot.view->raise();
	slot.embedded = true;

	if (!slot.placeholder && slot.home) {
		auto *label = new QLabel(text("Dock.Embedded"), slot.home);
		label->setAlignment(Qt::AlignCenter);
		label->setWordWrap(true);
		if (auto *layout = qobject_cast<QBoxLayout *>(slot.home->layout()))
			layout->addWidget(label, 1);
		slot.placeholder = label;
	}
	if (slot.placeholder)
		slot.placeholder->show();

	obs_log(LOG_INFO, "previsualización %s integrada en el hueco nativo", target == Main ? "principal" : "vertical");
}

void NativeIntegration::unembed(Target target)
{
	Slot &slot = slots_[target];
	slot.embedded = false;
	if (slot.placeholder)
		slot.placeholder->hide();
	if (!slot.view || !slot.home)
		return;
	slot.view->setMinimumSize(PreviewDock::kMinimumSize);
	if (auto *layout = qobject_cast<QBoxLayout *>(slot.home->layout()))
		layout->insertWidget(0, slot.view, 1);
	slot.view->show();
}

void NativeIntegration::setEnabled(Target target, bool enable)
{
	Slot &slot = slots_[target];
	if (slot.enabled == enable || stopped_)
		return;
	if (enable && (!locate(target) || !available(target)))
		return;

	slot.enabled = enable;
	apply(target);

	/* Si no se pudo activar, se deja como estaba. */
	if (enable && !slot.embedded) {
		slot.enabled = false;
		return;
	}
	if (onStateChanged_)
		onStateChanged_(target, enable);
}

void NativeIntegration::addMenuEntry(Target target, QMenu *menu)
{
	if (!menu || stopped_)
		return;
	locate(target);

	Slot &slot = slots_[target];
	QAction *before = menu->actions().isEmpty() ? nullptr : menu->actions().first();

	auto *action = new QAction(text("Menu.UseOptimized"), menu);
	action->setCheckable(true);
	action->setChecked(slot.enabled);
	action->setEnabled(slot.enabled || available(target));
	connect(action, &QAction::triggered, this, [this, target](bool checked) {
		/* Después de cerrar el menú, que es de OBS o de Vertical Canvas. */
		QTimer::singleShot(0, this, [this, target, checked]() { setEnabled(target, checked); });
	});

	menu->insertAction(before, action);
	if (before)
		menu->insertSeparator(before);
}

void NativeIntegration::arm(Target target)
{
	armed_ = target;
	armedAt_ = QDateTime::currentMSecsSinceEpoch();
	qApp->installEventFilter(this);
}

void NativeIntegration::disarm()
{
	if (armed_ >= 0)
		qApp->removeEventFilter(this);
	armed_ = -1;
}

bool NativeIntegration::eventFilter(QObject *watched, QEvent *event)
{
	if (stopped_)
		return false;

	const QEvent::Type type = event->type();

	/* Menú nativo a punto de mostrarse tras un clic derecho en la preview. */
	if (armed_ >= 0 && type == QEvent::Show) {
		auto *menu = qobject_cast<QMenu *>(watched);
		if (menu) {
			const Target target = Target(armed_);
			const bool recent = QDateTime::currentMSecsSinceEpoch() - armedAt_ <= kArmWindowMs;
			if (recent && menu->parentWidget() == slots_[target].menuParent) {
				disarm();
				addMenuEntry(target, menu);
				keepOnScreen(menu);
			} else if (!recent) {
				disarm();
			}
		}
		return false;
	}

	for (int t = 0; t < TargetCount; t++) {
		Slot &slot = slots_[t];

		if (watched == slot.disabledWidget) {
			if (type == QEvent::Resize && slot.embedded && slot.view)
				slot.view->setGeometry(slot.disabledWidget->rect());

			if (type == QEvent::ContextMenu && !slot.embedded) {
				if (t == Main) {
					arm(Main);
				} else {
					/* Vertical Canvas no tiene menú en su hueco desactivado. */
					QMenu menu;
					addMenuEntry(Vertical, &menu);
					menu.exec(static_cast<QContextMenuEvent *>(event)->globalPos());
					return true;
				}
			}
		} else if (watched == slot.nativePreview) {
			if (t == Main && type == QEvent::ContextMenu)
				arm(Main);
			/* Vertical Canvas abre su menú al soltar el botón derecho. */
			if (t == Vertical && type == QEvent::MouseButtonRelease &&
			    static_cast<QMouseEvent *>(event)->button() == Qt::RightButton)
				arm(Vertical);
		}
	}

	return false;
}

} // namespace nbp
