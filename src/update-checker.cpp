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

#include "update-checker.hpp"
#include "version-compare.hpp"

#include <obs-frontend-api.h>
#include <obs-module.h>
#include <util/bmem.h>

#include <curl/curl.h>

#include <QCoreApplication>
#include <QDialog>
#include <QDialogButtonBox>
#include <QLabel>
#include <QTextBrowser>
#include <QVBoxLayout>
#include <QMessageBox>
#include <QFont>
#include <QPushButton>
#include <QUrl>
#include <QDesktopServices>

#include <atomic>
#include <ctime>
#include <memory>
#include <string>
#include <thread>

#ifndef PLUGIN_VISIBLE_VERSION_STRING
#define PLUGIN_VISIBLE_VERSION_STRING "0"
#endif

namespace op {

namespace {

constexpr const char *kReleasesApi =
	"https://api.github.com/repos/Neotecos/obs-optimized-previews/releases?per_page=30";
constexpr size_t kMaxResponseBytes = 1024 * 1024;
constexpr long kCheckIntervalSeconds = 24 * 60 * 60;

struct Worker {
	std::thread thread;
	std::shared_ptr<std::atomic<bool>> cancelled = std::make_shared<std::atomic<bool>>(false);
};

std::unique_ptr<Worker> g_worker;
bool g_startup_check_done = false;

size_t write_body(char *data, size_t size, size_t count, void *user)
{
	auto *body = static_cast<std::string *>(user);
	const size_t bytes = size * count;
	if (body->size() + bytes > kMaxResponseBytes)
		return 0;
	body->append(data, bytes);
	return bytes;
}

int check_cancelled(void *user, curl_off_t, curl_off_t, curl_off_t, curl_off_t)
{
	return static_cast<std::atomic<bool> *>(user)->load() ? 1 : 0;
}

bool fetch_latest_release(std::atomic<bool> &cancelled, std::string &body)
{
	CURL *curl = curl_easy_init();
	if (!curl)
		return false;

	const std::string user_agent = std::string("obs-optimized-previews/") + PLUGIN_VISIBLE_VERSION_STRING;
	curl_slist *headers = nullptr;
	headers = curl_slist_append(headers, "Accept: application/vnd.github+json");
	headers = curl_slist_append(headers, "X-GitHub-Api-Version: 2022-11-28");

	curl_easy_setopt(curl, CURLOPT_URL, kReleasesApi);
	curl_easy_setopt(curl, CURLOPT_USERAGENT, user_agent.c_str());
	curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
	curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_body);
	curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
	curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
	curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
	curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
	curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
	curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
	curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, check_cancelled);
	curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &cancelled);

	const CURLcode result = curl_easy_perform(curl);
	long status = 0;
	curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);

	curl_slist_free_all(headers);
	curl_easy_cleanup(curl);
	return result == CURLE_OK && status == 200;
}

void stop_worker()
{
	if (!g_worker)
		return;
	g_worker->cancelled->store(true);
	if (g_worker->thread.joinable())
		g_worker->thread.join();
	g_worker.reset();
}

} // namespace

void updateCheckerShowDialog(const OPUpdateResult &result, UpdateSettings &settings,
			     std::function<void()> onChanged)
{
	const QString current = QString::fromLatin1(PLUGIN_VISIBLE_VERSION_STRING);

	auto *dialog = new QDialog(static_cast<QWidget *>(obs_frontend_get_main_window()));
	dialog->setAttribute(Qt::WA_DeleteOnClose);
	dialog->setWindowTitle(QString::fromUtf8(obs_module_text("Settings.Title")));
	dialog->setWindowModality(Qt::NonModal);

	auto *layout = new QVBoxLayout(dialog);
	auto *message = new QLabel(QString::fromUtf8(obs_module_text("Update.Available")).arg(result.version, current));
	message->setWordWrap(true);
	layout->addWidget(message);

	if (!result.notes.isEmpty()) {
		auto *heading = new QLabel(QString::fromUtf8(obs_module_text("Update.ReleaseNotes")));
		QFont bold = heading->font();
		bold.setBold(true);
		heading->setFont(bold);
		layout->addWidget(heading);

		auto *notes = new QTextBrowser();
		notes->setOpenExternalLinks(true);
		notes->setMarkdown(result.notes);
		notes->setMinimumHeight(180);
		layout->addWidget(notes, 1);
	}

	auto *buttons = new QDialogButtonBox();
	auto *open = buttons->addButton(QString::fromUtf8(obs_module_text("Update.OpenRelease")),
					QDialogButtonBox::AcceptRole);
	auto *later =
		buttons->addButton(QString::fromUtf8(obs_module_text("Update.Later")), QDialogButtonBox::RejectRole);
	auto *skip = buttons->addButton(QString::fromUtf8(obs_module_text("Update.SkipVersion")),
					QDialogButtonBox::DestructiveRole);
	layout->addWidget(buttons);

	const QString url = result.url;
	const QString version = result.version;
	QObject::connect(open, &QPushButton::clicked, dialog, [url]() { QDesktopServices::openUrl(QUrl(url)); });
	QObject::connect(later, &QPushButton::clicked, dialog, &QDialog::close);
	QObject::connect(skip, &QPushButton::clicked, dialog, [dialog, version, &settings, onChanged]() {
		settings.skippedVersion = version.toStdString();
		if (onChanged)
			onChanged();
		dialog->close();
	});

	dialog->resize(result.notes.isEmpty() ? 460 : 560, result.notes.isEmpty() ? 140 : 460);
	dialog->show();
	dialog->raise();
	dialog->activateWindow();
}

void updateCheckerCheck(std::function<void(const OPUpdateResult &)> done)
{
	stop_worker();

	g_worker = std::make_unique<Worker>();
	auto cancelled = g_worker->cancelled;
	g_worker->thread = std::thread([cancelled, done = std::move(done)]() {
		std::string body;
		OPUpdateResult result;
		if (fetch_latest_release(*cancelled, body))
			result = op_evaluate_releases(QByteArray::fromStdString(body), QString::fromLatin1(PLUGIN_VISIBLE_VERSION_STRING));

		if (cancelled->load())
			return;

		QMetaObject::invokeMethod(
			QCoreApplication::instance(),
			[cancelled, done, result]() {
				if (!cancelled->load())
					done(result);
			},
			Qt::QueuedConnection);
	});
}

void updateCheckerCheckOnStartup(UpdateSettings &settings, std::function<void()> onChanged)
{
	if (g_startup_check_done || !settings.checkOnStartup)
		return;
	g_startup_check_done = true;

	const long long now = static_cast<long long>(std::time(nullptr));
	if (settings.lastCheck > 0 && now >= settings.lastCheck && now - settings.lastCheck < kCheckIntervalSeconds)
		return;

	/* Se anota antes de la petición para no reintentar en cada arranque sin red. */
	settings.lastCheck = now;
	if (onChanged)
		onChanged();

	updateCheckerCheck([&settings, onChanged](const OPUpdateResult &result) {
		if (result.status != OPUpdateResult::Status::Available)
			return;

		/* Una versión omitida no avisa aquí; la comprobación manual sí la muestra. */
		if (result.version.toStdString() != settings.skippedVersion)
			updateCheckerShowDialog(result, settings, onChanged);
	});
}

void updateCheckerShutdown()
{
	stop_worker();
}

} // namespace op
