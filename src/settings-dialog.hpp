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

#include <functional>

class QWidget;

namespace op {

/* Cambios automáticos entre la previsualización nativa y la optimizada. */
struct AutoSwitchSettings {
	bool onStreamStart = false;
	bool onRecordStart = false;
	bool onStreamStop = false;
	bool onRecordStop = false;
};

/* Abre (o trae al frente) la ventana de opciones de Herramientas. Cada
 * cambio se aplica al momento y llama a `onChanged`. */
void showSettingsDialog(QWidget *parent, AutoSwitchSettings &settings, std::function<void()> onChanged);

/* Cierra la ventana si está abierta (al cerrar OBS). */
void closeSettingsDialog();

} // namespace op
