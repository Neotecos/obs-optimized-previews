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

#include <QString>
#include <QByteArray>

/* True when `latest` is a newer dotted version than `current`. A leading "v"
 * and anything after a "-" or "+" are ignored; non-numeric input never counts
 * as newer. */
bool op_version_is_newer(const QString &latest, const QString &current);

struct OPUpdateResult {
	enum class Status { UpToDate, Available, Failed };

	Status status = Status::Failed;
	QString version; /* newest release, without a leading "v" */
	QString url;     /* its release page, always on the project's GitHub repository */
	QString notes;   /* notes of every release newer than the current one, newest first, in Markdown */
};

/* Reads GitHub's list-releases JSON and reports whether a published release is
 * newer than `current`. Drafts and prereleases are ignored. `version` and
 * `url` describe the newest release; `notes` joins the notes of every newer
 * release, each under its version heading. Malformed input gives Failed. */
OPUpdateResult op_evaluate_releases(const QByteArray &json, const QString &current);
