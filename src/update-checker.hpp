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

#include "version-compare.hpp"

#include <functional>
#include <string>

namespace op {

/* Estado persistente de la comprobación de versiones nuevas. */
struct UpdateSettings {
	bool checkOnStartup = true;
	long long lastCheck = 0;
	std::string skippedVersion;
};

/* Consulta las releases de GitHub en un hilo aparte. `done` se ejecuta en el
 * hilo principal, y no se ejecuta una vez iniciado el cierre. */
void updateCheckerCheck(std::function<void(const OPUpdateResult &)> done);

/* Aviso de versión nueva con las notas de la release (no modal). Permite abrir
 * la página, posponerlo u omitir esa versión. */
void updateCheckerShowDialog(const OPUpdateResult &result, UpdateSettings &settings,
			     std::function<void()> onChanged);

/* Comprobación silenciosa como mucho una vez al día; solo avisa si hay una
 * versión más reciente. No hace nada si está desactivada al iniciar. */
void updateCheckerCheckOnStartup(UpdateSettings &settings, std::function<void()> onChanged);

void updateCheckerShutdown();

} // namespace op
