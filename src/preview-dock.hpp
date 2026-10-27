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

#include <QString>
#include <QWidget>

namespace nbp {

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

	QPaintEngine *paintEngine() const override { return nullptr; }

signals:
	void fpsLimitSelected(unsigned int fps);

protected:
	bool event(QEvent *event) override;
	void showEvent(QShowEvent *event) override;
	void hideEvent(QHideEvent *event) override;
	void contextMenuEvent(QContextMenuEvent *event) override;

private:
	void attachView();
	void detachView();

	PreviewShared &shared_;
	void *view_ = nullptr; /* NBPPreviewView *, retenido (CFBridgingRetain) */
	QString message_;
	bool shutdown_ = false;
};

} // namespace nbp
