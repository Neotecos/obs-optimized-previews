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

#include "version-compare.hpp"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QRegularExpression>

#include <algorithm>

bool op_version_is_newer(const QString &latest, const QString &current)
{
	auto parse = [](const QString &text, QList<int> &parts) {
		QString version = text.trimmed();
		if (version.startsWith(QLatin1Char('v')) || version.startsWith(QLatin1Char('V')))
			version.remove(0, 1);
		const qsizetype cut = version.indexOf(QRegularExpression(QStringLiteral("[-+]")));
		if (cut >= 0)
			version.truncate(cut);

		parts.clear();
		for (const QString &piece : version.split(QLatin1Char('.'))) {
			bool ok = false;
			const int value = piece.toInt(&ok);
			if (!ok || value < 0)
				return false;
			parts.append(value);
		}
		return !parts.isEmpty();
	};

	QList<int> a, b;
	if (!parse(latest, a) || !parse(current, b))
		return false;

	const qsizetype count = std::max(a.size(), b.size());
	for (qsizetype i = 0; i < count; i++) {
		const int x = i < a.size() ? a[i] : 0;
		const int y = i < b.size() ? b[i] : 0;
		if (x != y)
			return x > y;
	}
	return false;
}

namespace {

constexpr const char *kReleasesPage = "https://github.com/Neotecos/obs-optimized-previews/releases";
constexpr const char *kReleaseUrlPrefix = "https://github.com/Neotecos/obs-optimized-previews/";
constexpr qsizetype kMaxNotesChars = 40000;

struct Release {
	QString version;
	QString url;
	QString notes;
};

QString strip_v(QString tag)
{
	if (tag.startsWith(QLatin1Char('v')) || tag.startsWith(QLatin1Char('V')))
		tag.remove(0, 1);
	return tag;
}

} // namespace

OPUpdateResult op_evaluate_releases(const QByteArray &json, const QString &current)
{
	OPUpdateResult result;

	const QJsonDocument doc = QJsonDocument::fromJson(json);
	if (!doc.isArray())
		return result;

	QList<Release> newer;
	const QJsonArray releases = doc.array();
	for (const QJsonValue value : releases) {
		const QJsonObject release = value.toObject();
		if (release.value(QStringLiteral("draft")).toBool() || release.value(QStringLiteral("prerelease")).toBool())
			continue;

		const QString version = strip_v(release.value(QStringLiteral("tag_name")).toString());
		if (!op_version_is_newer(version, current))
			continue;

		/* The link is opened in the user's browser, so only accept one that
		 * points back at this project. */
		QString url = release.value(QStringLiteral("html_url")).toString();
		if (!url.startsWith(QLatin1String(kReleaseUrlPrefix)))
			url = QString::fromLatin1(kReleasesPage);

		newer.append({version, url, release.value(QStringLiteral("body")).toString().trimmed()});
	}

	result.status = newer.isEmpty() ? OPUpdateResult::Status::UpToDate : OPUpdateResult::Status::Available;
	if (newer.isEmpty())
		return result;

	std::stable_sort(newer.begin(), newer.end(),
			 [](const Release &a, const Release &b) { return op_version_is_newer(a.version, b.version); });

	result.version = newer.first().version;
	result.url = newer.first().url;

	QStringList sections;
	for (const Release &release : newer) {
		QString section = QStringLiteral("## %1").arg(release.version);
		if (!release.notes.isEmpty())
			section += QStringLiteral("\n\n") + release.notes;
		sections.append(section);
	}
	result.notes = sections.join(QStringLiteral("\n\n---\n\n"));
	if (result.notes.size() > kMaxNotesChars)
		result.notes = result.notes.left(kMaxNotesChars) + QStringLiteral("\n\n…");
	return result;
}
