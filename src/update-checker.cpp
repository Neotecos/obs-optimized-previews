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

#include <QEventLoop>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTimer>

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

bool fetch_latest_release(std::atomic<bool> &cancelled, std::string &body)
{
	QNetworkAccessManager manager;
	QNetworkRequest request{QUrl(QString::fromLatin1(kReleasesApi))};
	request.setRawHeader("User-Agent", QByteArray("obs-optimized-previews/") + PLUGIN_VISIBLE_VERSION_STRING);
	request.setRawHeader("Accept", "application/vnd.github+json");
	request.setRawHeader("X-GitHub-Api-Version", "2022-11-28");
	request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
	request.setTransferTimeout(10000);
	auto *reply = manager.get(request);
	QEventLoop loop;
	QTimer cancelTimer, deadline;
	deadline.setSingleShot(true);
	QObject::connect(&deadline, &QTimer::timeout, reply, &QNetworkReply::abort);
	QObject::connect(&cancelTimer, &QTimer::timeout, reply, [&]() {
		if (cancelled.load())
			reply->abort();
	});
	QObject::connect(reply, &QNetworkReply::readyRead, reply, [&]() {
		const QByteArray chunk = reply->readAll();
		if (body.size() + size_t(chunk.size()) > kMaxResponseBytes)
			reply->abort();
		else
			body.append(chunk.constData(), size_t(chunk.size()));
	});
	QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
	cancelTimer.start(50);
	deadline.start(10000);
	loop.exec();
	return !cancelled.load() && reply->error() == QNetworkReply::NoError &&
	       reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 200;
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
