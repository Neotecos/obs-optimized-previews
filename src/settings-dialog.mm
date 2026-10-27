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
#include <QDialog>
#include <QDialogButtonBox>
#include <QGroupBox>
#include <QLabel>
#include <QPointer>
#include <QVBoxLayout>

namespace op {

namespace {

QString text(const char *key)
{
	return QString::fromUtf8(obs_module_text(key));
}

QPointer<QDialog> openDialog;

} // namespace

void showSettingsDialog(QWidget *parent, AutoSwitchSettings &settings, std::function<void()> onChanged)
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
