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

#include "canvas-tracker.hpp"
#include "native-integration.hpp"
#include "preview-coordinator.hpp"
#include "preview-dock.hpp"

#include <obs-module.h>
#include <obs-frontend-api.h>
#include <util/bmem.h>
#include <util/platform.h>
#include <plugin-support.h>

#include <QActionGroup>
#include <QMainWindow>
#include <QMenu>
#include <QVBoxLayout>
#include <QPointer>
#include <QTimer>

#include <memory>
#include <string>
#include <vector>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE(PLUGIN_NAME, "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
	return obs_module_text("Description");
}

namespace {

const char *const kDockMainId = "nbp-preview-main";
const char *const kDockVerticalId = "nbp-preview-vertical";

const char *const kDefaultVerticalCanvas = "Aitum Vertical";

struct Settings {
	uint32_t mainFps = 0;
	uint32_t verticalFps = 0;
	std::string verticalName = kDefaultVerticalCanvas;
	std::string verticalUuid;
	bool mainIntegrated = false;
	bool verticalIntegrated = false;
};

struct Plugin {
	nbp::PreviewCoordinator coordinator;

	/* Solo hilo principal. */
	Settings settings;
	QPointer<nbp::NativeIntegration> integration;
	std::unique_ptr<nbp::CanvasTracker> tracker;
	QPointer<QTimer> rendererCheckTimer;
	bool callbackRegistered = false;
	bool verticalFound = false;
};

Plugin *plugin = nullptr;

nbp::PreviewDock *previewView(nbp::NativeIntegration::Target target)
{
	return plugin && plugin->integration ? plugin->integration->view(target) : nullptr;
}

void renderedCallback(void *)
{
	if (plugin)
		plugin->coordinator.onRendered();
}

void renderCallback(void *, uint32_t, uint32_t)
{
	if (plugin)
		plugin->coordinator.onBeforeRender();
}

/* ---------------------------------------------------------------------- */
/* Hilo principal                                                         */

std::string configPath()
{
	char *path = obs_module_config_path("settings.json");
	std::string result = path ? path : "";
	bfree(path);
	return result;
}

void loadSettings(Settings &settings)
{
	const std::string path = configPath();
	obs_data_t *data = obs_data_create_from_json_file_safe(path.c_str(), "bak");
	if (!data)
		return;

	obs_data_set_default_string(data, "vertical_canvas_name", kDefaultVerticalCanvas);
	settings.mainFps = uint32_t(obs_data_get_int(data, "main_fps"));
	settings.verticalFps = uint32_t(obs_data_get_int(data, "vertical_fps"));
	settings.verticalName = obs_data_get_string(data, "vertical_canvas_name");
	settings.verticalUuid = obs_data_get_string(data, "vertical_canvas_uuid");
	settings.mainIntegrated = obs_data_get_bool(data, "main_integrated");
	settings.verticalIntegrated = obs_data_get_bool(data, "vertical_integrated");
	obs_data_release(data);
}

void saveSettings(const Settings &settings)
{
	char *directory = obs_module_config_path("");
	if (directory) {
		os_mkdirs(directory);
		bfree(directory);
	}

	obs_data_t *data = obs_data_create();
	obs_data_set_int(data, "main_fps", settings.mainFps);
	obs_data_set_int(data, "vertical_fps", settings.verticalFps);
	obs_data_set_string(data, "vertical_canvas_name", settings.verticalName.c_str());
	obs_data_set_string(data, "vertical_canvas_uuid", settings.verticalUuid.c_str());
	obs_data_set_bool(data, "main_integrated", settings.mainIntegrated);
	obs_data_set_bool(data, "vertical_integrated", settings.verticalIntegrated);
	if (!obs_data_save_json_safe(data, configPath().c_str(), "tmp", "bak"))
		obs_log(LOG_WARNING, "no se pudo guardar la configuración");
	obs_data_release(data);
}

QString text(const char *key)
{
	return QString::fromUtf8(obs_module_text(key));
}

void updateMessages()
{
	if (!plugin)
		return;

	const bool unsupported = plugin->coordinator.unsupportedRenderer.load();
	if (nbp::PreviewDock *main = previewView(nbp::NativeIntegration::Main))
		main->setMessage(unsupported ? text("Message.UnsupportedRenderer") : QString());

	nbp::PreviewDock *vertical = previewView(nbp::NativeIntegration::Vertical);
	if (!vertical)
		return;
	if (unsupported)
		vertical->setMessage(text("Message.UnsupportedRenderer"));
	else if (!plugin->verticalFound)
		vertical->setMessage(
			text("Message.CanvasMissing").arg(QString::fromStdString(plugin->settings.verticalName)));
	else
		vertical->setMessage(QString());
}

void extendMainMenu(QMenu *menu)
{
	if (plugin && plugin->integration)
		plugin->integration->addMenuEntry(nbp::NativeIntegration::Main, menu);
}

/* Opción de integración y submenú del dock vertical para elegir el canvas. */
void extendVerticalMenu(QMenu *menu)
{
	if (plugin && plugin->integration)
		plugin->integration->addMenuEntry(nbp::NativeIntegration::Vertical, menu);

	struct Entry {
		std::string name;
		std::string uuid;
	};
	std::vector<Entry> canvases;
	obs_enum_canvases(
		[](void *param, obs_canvas_t *canvas) {
			if (!(obs_canvas_get_flags(canvas) & MAIN) && !obs_canvas_removed(canvas))
				static_cast<std::vector<Entry> *>(param)->push_back(
					{obs_canvas_get_name(canvas), obs_canvas_get_uuid(canvas)});
			return true;
		},
		&canvases);

	QMenu *canvasMenu = menu->addMenu(text("Menu.Canvas"));
	if (canvases.empty()) {
		canvasMenu->addAction(text("Menu.Canvas.None"))->setEnabled(false);
		return;
	}

	auto *group = new QActionGroup(canvasMenu);
	for (const Entry &entry : canvases) {
		QAction *action = canvasMenu->addAction(QString::fromStdString(entry.name));
		action->setCheckable(true);
		action->setChecked(entry.name == plugin->settings.verticalName);
		group->addAction(action);
		QObject::connect(action, &QAction::triggered, [entry]() {
			if (!plugin)
				return;
			plugin->settings.verticalName = entry.name;
			plugin->settings.verticalUuid = entry.uuid;
			saveSettings(plugin->settings);
			if (plugin->tracker)
				plugin->tracker->setTarget(entry.name, entry.uuid);
			updateMessages();
		});
	}
}

void removeRenderCallback()
{
	if (plugin && plugin->callbackRegistered) {
		/* Al volver, ningún callback nuestro está en ejecución: libobs los
		 * llama con draw_callbacks_mutex tomado. */
		obs_remove_main_render_callback(renderCallback, nullptr);
		obs_remove_main_rendered_callback(renderedCallback, nullptr);
		plugin->callbackRegistered = false;
	}
}

void logStatistics(const char *label, const nbp::PreviewShared &shared)
{
	const uint64_t count = shared.latencyCount.load();
	const double averageMs = count ? double(shared.latencySumNs.load()) / double(count) / 1e6 : 0.0;
	obs_log(LOG_INFO,
		"%s: %llu fotogramas publicados, %llu sin superficie libre, latencia hasta Core Animation "
		"media %.1f ms, máxima %.1f ms",
		label, (unsigned long long)shared.framesPublished.load(),
		(unsigned long long)shared.framesSkippedBusy.load(), averageMs,
		double(shared.latencyMaxNs.load()) / 1e6);
	obs_log(LOG_INFO,
		"%s: %llu fotogramas entregados a Core Animation, %llu sustituidos antes de mostrarse, "
		"%llu huecos de más de 1,5 fotogramas",
		label, (unsigned long long)shared.framesPresented.load(),
		(unsigned long long)shared.framesSuperseded.load(), (unsigned long long)shared.presentGaps.load());
}

/* Cierre en el hilo principal mientras Qt sigue vivo. */
void shutdownFrontend()
{
	if (!plugin)
		return;

	removeRenderCallback();
	if (plugin->tracker) {
		plugin->tracker->stopAfterCallbackRemoved();
		plugin->tracker.reset();
	}
	if (plugin->rendererCheckTimer)
		delete plugin->rendererCheckTimer.data();
	if (plugin->integration) {
		plugin->integration->shutdown();
		for (auto target : {nbp::NativeIntegration::Main, nbp::NativeIntegration::Vertical}) {
			if (nbp::PreviewDock *view = plugin->integration->view(target))
				view->shutdown();
		}
		delete plugin->integration.data();
	}
}

void frontendEvent(enum obs_frontend_event event, void *)
{
	if (event == OBS_FRONTEND_EVENT_FINISHED_LOADING && plugin) {
		/* Después de que OBS aplique su propio estado de previsualización. */
		QTimer::singleShot(0, []() {
			if (plugin && plugin->integration)
				plugin->integration->start(plugin->settings.mainIntegrated,
							   plugin->settings.verticalIntegrated);
		});
	}
	if (event == OBS_FRONTEND_EVENT_EXIT && plugin) {
		logStatistics("horizontal", plugin->coordinator.mainShared);
		logStatistics("vertical", plugin->coordinator.verticalShared);
		shutdownFrontend();
	}
}

nbp::PreviewDock *createView(nbp::PreviewShared &shared, bool vertical)
{
	auto *view = new nbp::PreviewDock(shared);
	QObject::connect(view, &nbp::PreviewDock::fpsLimitSelected, view, [vertical](unsigned int fps) {
		if (!plugin)
			return;
		(vertical ? plugin->settings.verticalFps : plugin->settings.mainFps) = fps;
		saveSettings(plugin->settings);
	});
	view->setMenuExtender(vertical ? extendVerticalMenu : extendMainMenu);
	/* Una previsualización recreada recupera su mensaje. */
	QTimer::singleShot(0, []() { updateMessages(); });
	return view;
}

/* El dock propio aloja la previsualización cuando no está integrada en la
 * nativa, y es la alternativa si la integración deja de encajar. */
void addDock(const char *id, const char *titleKey, nbp::NativeIntegration::Target target,
	     nbp::PreviewShared &shared)
{
	auto *home = new QWidget();
	auto *layout = new QVBoxLayout(home);
	layout->setContentsMargins(0, 0, 0, 0);
	layout->setSpacing(0);

	const bool vertical = target == nbp::NativeIntegration::Vertical;
	plugin->integration->setHome(target, home, [&shared, vertical]() { return createView(shared, vertical); });

	if (!obs_frontend_add_dock_by_id(id, obs_module_text(titleKey), home))
		obs_log(LOG_ERROR, "no se pudo añadir el dock «%s»", id);
}

} // namespace

bool obs_module_load(void)
{
	plugin = new Plugin();
	loadSettings(plugin->settings);
	nbp::PreviewCoordinator &coordinator = plugin->coordinator;
	coordinator.mainShared.fpsLimit.store(plugin->settings.mainFps);
	coordinator.verticalShared.fpsLimit.store(plugin->settings.verticalFps);

	plugin->integration = new nbp::NativeIntegration(
		static_cast<QMainWindow *>(obs_frontend_get_main_window()),
		[](nbp::NativeIntegration::Target target, bool enabled) {
			if (!plugin)
				return;
			(target == nbp::NativeIntegration::Main ? plugin->settings.mainIntegrated
								 : plugin->settings.verticalIntegrated) = enabled;
			saveSettings(plugin->settings);
		});
	addDock(kDockMainId, "Dock.Main", nbp::NativeIntegration::Main, coordinator.mainShared);
	addDock(kDockVerticalId, "Dock.Vertical", nbp::NativeIntegration::Vertical, coordinator.verticalShared);

	plugin->tracker = std::make_unique<nbp::CanvasTracker>(coordinator.verticalCanvas,
								 coordinator.verticalCanvasSize,
								 coordinator.relearnVertical, coordinator.graphicsCallbacks);
	plugin->tracker->setTarget(plugin->settings.verticalName, plugin->settings.verticalUuid);
	plugin->tracker->setStatusCallback([](bool found) {
		if (!plugin)
			return;
		plugin->verticalFound = found;
		updateMessages();
	});
	updateMessages();

	obs_add_main_render_callback(renderCallback, nullptr);
	obs_add_main_rendered_callback(renderedCallback, nullptr);
	plugin->callbackRegistered = true;
	obs_frontend_add_event_callback(frontendEvent, nullptr);

	/* Vertical Canvas crea su canvas durante su propia carga; el
	 * seguimiento empieza cuando el bucle de eventos ya está en marcha (y
	 * las señales canvas_create cubren lo que llegue después). */
	QTimer::singleShot(0, []() {
		if (plugin && plugin->tracker)
			plugin->tracker->start();
	});

	/* El tipo de renderizador solo se conoce en el hilo gráfico. */
	auto *timer = new QTimer();
	plugin->rendererCheckTimer = timer;
	QObject::connect(timer, &QTimer::timeout, timer, [timer]() {
		if (!plugin || !plugin->coordinator.checkedRenderer.load())
			return;
		if (plugin->coordinator.unsupportedRenderer.load())
			updateMessages();
		timer->deleteLater();
	});
	timer->start(1000);

	obs_log(LOG_INFO, "plugin cargado (versión %s)", PLUGIN_VERSION);
	return true;
}

void obs_module_unload(void)
{
	if (!plugin)
		return;

	obs_frontend_remove_event_callback(frontendEvent, nullptr);
	shutdownFrontend();

	/* El hilo gráfico ya está detenido; liberamos los recursos GL dentro del
	 * contexto, que es el único momento en que este código lo toma. */
	obs_enter_graphics();
	plugin->coordinator.destroyGraphics();
	obs_leave_graphics();
	plugin->coordinator.releasePublished();

	delete plugin;
	plugin = nullptr;
	obs_log(LOG_INFO, "plugin descargado");
}
