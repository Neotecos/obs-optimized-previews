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

#include <QObject>
#include <QPointer>

#include <functional>

class QMainWindow;
class QMenu;
class QTimer;
class QWidget;

namespace op {

class PreviewDock;

/* Sustituye la previsualización nativa (lienzo principal de OBS y canvas de
 * Vertical Canvas) por la del plugin, en el mismo hueco, y añade la opción
 * al menú contextual nativo. Vive en el hilo principal.
 *
 * Usa API pública para activar y desactivar las previews nativas
 * (obs_frontend_set_preview_enabled y los atajos públicos de Vertical
 * Canvas), pero localizar sus widgets y sus menús depende de detalles
 * internos de Qt de OBS 33 y Vertical Canvas 1.6.x. Si no los encuentra,
 * la previsualización del plugin sigue en su dock y la opción no aparece. */
class NativeIntegration : public QObject {
public:
	enum Target { Main = 0, Vertical = 1, TargetCount = 2 };
	using StateFn = std::function<void(Target target, bool enabled)>;
	using ViewFactory = std::function<PreviewDock *()>;

	NativeIntegration(QMainWindow *mainWindow, StateFn onStateChanged);
	~NativeIntegration() override;

	/* `home` es el contenido del dock propio (con un QVBoxLayout), donde
	 * vive la previsualización cuando no está integrada. La fábrica crea la
	 * previsualización ahora y de nuevo si el widget nativo que la aloja se
	 * destruye (p. ej., si Vertical Canvas recrea su dock). */
	void setHome(Target target, QWidget *home, ViewFactory factory);
	PreviewDock *view(Target target) const;

	/* Aplica el estado guardado; se llama cuando OBS ha terminado de cargar. */
	void start(bool mainEnabled, bool verticalEnabled);

	/* Al cerrar OBS: deja de interceptar eventos. Las previews nativas se
	 * quedan como están para que su estado se guarde. */
	void shutdown();

	/* Preferencia guardada (puede estar pendiente de aplicar). */
	bool enabled(Target target) const { return slots_[target].enabled; }
	/* Si la previsualización está ahora mismo en el hueco nativo. */
	bool active(Target target) const { return slots_[target].embedded; }

	/* Si es false, no se buscan periódicamente los widgets nativos de ese
	 * destino (p. ej., la vertical cuando Vertical Canvas no está instalado). */
	void setSearchEnabled(Target target, bool search) { slots_[target].search = search; }
	void setEnabled(Target target, bool enable);

	/* Añade la opción al principio de un menú (el nativo o el del dock). */
	void addMenuEntry(Target target, QMenu *menu);

protected:
	bool eventFilter(QObject *watched, QEvent *event) override;

private:
	struct Slot {
		ViewFactory factory;
		QPointer<PreviewDock> view;
		QPointer<QWidget> home;
		QPointer<QWidget> placeholder;
		QPointer<QWidget> nativePreview;
		QPointer<QWidget> disabledWidget;
		QPointer<QWidget> menuParent;
		bool enabled = false;
		bool embedded = false;
		bool search = true;
	};

	bool locate(Target target);
	bool locateMain(Slot &slot);
	bool locateVertical(Slot &slot);
	bool available(Target target) const;
	bool setNativeEnabled(Target target, bool enable);
	void apply(Target target);
	void embed(Target target);
	void unembed(Target target);
	void createView(Target target);
	void arm(Target target);
	void disarm();

	QPointer<QMainWindow> mainWindow_;
	StateFn onStateChanged_;
	Slot slots_[TargetCount];
	QTimer *retryTimer_ = nullptr;
	int armed_ = -1;
	qint64 armedAt_ = 0;
	bool started_ = false;
	bool stopped_ = false;
};

} // namespace op
