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

#include "preview-shared.hpp"

#include <QString>
#include <QWidget>

#include <functional>

class QMenu;

namespace op {

/* Contenido de un dock: un QWidget nativo que aloja un NSView con una capa
 * de Core Animation cuyo `contents` es la última IOSurface publicada por el
 * hilo gráfico. Vive en el hilo principal y nunca toca el contexto gráfico. */
class PreviewDock : public QWidget {
	Q_OBJECT

public:
	explicit PreviewDock(PreviewShared &shared, QWidget *parent = nullptr);
	~PreviewDock() override;

	/* Texto superpuesto (p. ej., «canvas no encontrado»). Vacío lo oculta. */
	void setMessage(const QString &message);

	/* Deja de presentar y de pedir fotogramas (al cerrar OBS). */
	void shutdown();

	/* Permite añadir entradas propias al menú contextual. */
	void setMenuExtender(std::function<void(QMenu *)> extender) { menuExtender_ = std::move(extender); }

#ifdef __APPLE__
	QPaintEngine *paintEngine() const override { return nullptr; }
#else
	void paintEvent(QPaintEvent *event) override;
#endif

	/* Tamaño mínimo cuando está en su propio dock. */
	static constexpr QSize kMinimumSize{160, 90};

signals:
	void fpsLimitSelected(unsigned int fps);

protected:
	bool event(QEvent *event) override;
	void showEvent(QShowEvent *event) override;
	void hideEvent(QHideEvent *event) override;
	void contextMenuEvent(QContextMenuEvent *event) override;

private:
#ifdef __APPLE__
	void attachView();
	void detachView();
#else
	void step();
	QImage image_;
	uint64_t seenSerial_ = 0;
	uint64_t lastFrameTime_ = 0;
	uint64_t lastPresentTime_ = 0;
	uint64_t pendingSize_ = 0;
	uint64_t pendingSince_ = 0;
#endif

	PreviewShared &shared_;
	void *view_ = nullptr; /* OPPreviewView *, retenido (CFBridgingRetain) */
	QString message_;
	std::function<void(QMenu *)> menuExtender_;
	bool shutdown_ = false;
};

} // namespace op
