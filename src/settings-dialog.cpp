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

#include "settings-dialog.hpp"

#include <obs-module.h>

#include <QCheckBox>
#include <QHBoxLayout>
#include <QPushButton>
#include <QDialog>
#include <QDialogButtonBox>
#include <QGroupBox>
#include <QLabel>
#include <QPointer>
#include <QVBoxLayout>

#include <ctime>

namespace op {

namespace {

QString text(const char *key)
{
	return QString::fromUtf8(obs_module_text(key));
}

QPointer<QDialog> openDialog;

#ifndef PLUGIN_VISIBLE_VERSION_STRING
#define PLUGIN_VISIBLE_VERSION_STRING "0"
#endif

} // namespace

void showSettingsDialog(QWidget *parent, AutoSwitchSettings &settings, UpdateSettings &updates,
			std::function<void()> onChanged)
{
	if (openDialog) {
		openDialog->raise();
		openDialog->activateWindow();
		return;
	}

	auto *dialog = new QDialog(parent);
	dialog->setAttribute(Qt::WA_DeleteOnClose);
	dialog->setWindowTitle(text("Settings.Title"));
	openDialog = dialog;

	auto *layout = new QVBoxLayout(dialog);
	auto *group = new QGroupBox(text("Settings.Automatic"), dialog);
	auto *groupLayout = new QVBoxLayout(group);

	const struct {
		const char *label;
		bool AutoSwitchSettings::*field;
	} options[] = {
		{"Settings.OnStreamStart", &AutoSwitchSettings::onStreamStart},
		{"Settings.OnRecordStart", &AutoSwitchSettings::onRecordStart},
		{"Settings.OnStreamStop", &AutoSwitchSettings::onStreamStop},
		{"Settings.OnRecordStop", &AutoSwitchSettings::onRecordStop},
	};

	for (const auto &option : options) {
		auto *check = new QCheckBox(text(option.label), group);
		check->setChecked(settings.*option.field);
		const auto field = option.field;
		QObject::connect(check, &QCheckBox::toggled, dialog, [&settings, field, onChanged](bool checked) {
			settings.*field = checked;
			if (onChanged)
				onChanged();
		});
		groupLayout->addWidget(check);
	}

	auto *note = new QLabel(text("Settings.Note"), group);
	note->setWordWrap(true);
	note->setEnabled(false);
	groupLayout->addWidget(note);
	layout->addWidget(group);

	auto *updatesGroup = new QGroupBox(text("Settings.Updates"), dialog);
	auto *updatesLayout = new QVBoxLayout(updatesGroup);

	auto *startupCheck = new QCheckBox(text("Settings.UpdateCheck"), updatesGroup);
	startupCheck->setChecked(updates.checkOnStartup);
	startupCheck->setToolTip(text("Settings.UpdateCheck.Tooltip"));
	QObject::connect(startupCheck, &QCheckBox::toggled, dialog, [&updates, onChanged](bool checked) {
		updates.checkOnStartup = checked;
		if (onChanged)
			onChanged();
	});
	updatesLayout->addWidget(startupCheck);

	auto *updateRow = new QHBoxLayout();
	auto *button = new QPushButton(text("Settings.UpdateCheck.Button"), updatesGroup);
	auto *status = new QLabel(text("Settings.UpdateCheck.Current") + QStringLiteral(PLUGIN_VISIBLE_VERSION_STRING),
				  updatesGroup);
	status->setWordWrap(true);
	status->setOpenExternalLinks(true);
	status->setTextInteractionFlags(Qt::TextBrowserInteraction);
	updateRow->addWidget(button);
	updateRow->addWidget(status, 1);
	updatesLayout->addLayout(updateRow);

	QObject::connect(button, &QPushButton::clicked, dialog,
			 [dialog, button, status, &updates, onChanged]() {
				 button->setEnabled(false);
				 status->setText(text("Settings.UpdateCheck.Checking"));
				 updates.lastCheck = static_cast<long long>(std::time(nullptr));
				 if (onChanged)
					 onChanged();

				 QPointer<QDialog> self(dialog);
				 updateCheckerCheck([self, button, status, &updates, onChanged](const OPUpdateResult &result) {
					 if (!self)
						 return;
					 button->setEnabled(true);
					 switch (result.status) {
					 case OPUpdateResult::Status::Available:
						 updateCheckerShowDialog(result, updates, onChanged);
						 status->setText(text("Settings.UpdateCheck.Available")
									 .arg(result.version.toHtmlEscaped(),
									      result.url.toHtmlEscaped()));
						 break;
					 case OPUpdateResult::Status::UpToDate:
						 status->setText(text("Settings.UpdateCheck.UpToDate")
									 .arg(QStringLiteral(PLUGIN_VISIBLE_VERSION_STRING)));
						 break;
					 case OPUpdateResult::Status::Failed:
						 status->setText(text("Settings.UpdateCheck.Failed"));
						 break;
					 }
				 });
			 });
	layout->addWidget(updatesGroup);

	auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close, dialog);
	QObject::connect(buttons, &QDialogButtonBox::rejected, dialog, &QDialog::close);
	layout->addWidget(buttons);

	dialog->show();
}

void closeSettingsDialog()
{
	if (openDialog)
		delete openDialog.data();
}

} // namespace op
