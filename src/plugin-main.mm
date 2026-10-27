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

#include "gl-scaler.hpp"
#include "preview-dock.hpp"
#include "preview-renderer.hpp"
#include "preview-shared.hpp"

#include <obs-module.h>
#include <obs-frontend-api.h>
#include <util/profiler.h>
#include <plugin-support.h>

#include <QMainWindow>
#include <QPointer>

#include <atomic>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE(PLUGIN_NAME, "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
	return obs_module_text("Description");
}

namespace {

const char *const kDockMainId = "nbp-preview-main";

const char *const kProfileCallback = "nbp_rendered_callback";
const char *const kProfileMain = "nbp_preview_main";

struct Plugin {
	nbp::GlScaler scaler;
	nbp::PreviewShared mainShared;
	nbp::PreviewRenderer mainRenderer{mainShared, scaler, kProfileMain};

	QPointer<nbp::PreviewDock> mainDock;

	bool callbackRegistered = false;
	/* Solo hilo gráfico. */
	bool checkedRenderer = false;
	bool unsupportedRenderer = false;
};

Plugin *plugin = nullptr;

/* Se ejecuta en el hilo gráfico al terminar de renderizar CADA mezcla de
 * vídeo (render_main_texture), no una vez por fotograma: el lienzo principal
 * se reconoce porque el render target actual es su textura. */
void renderedCallback(void *)
{
	Plugin *p = plugin;
	if (!p)
		return;

	if (!p->checkedRenderer) {
		p->checkedRenderer = true;
		p->unsupportedRenderer = gs_get_device_type() != GS_DEVICE_OPENGL;
		if (p->unsupportedRenderer)
			obs_log(LOG_WARNING, "El renderizador no es OpenGL; las previsualizaciones quedan desactivadas");
	}
	if (p->unsupportedRenderer)
		return;

	profile_start(kProfileCallback);

	p->mainRenderer.poll();

	const uint64_t frameTime = obs_get_video_frame_time();
	gs_texture_t *target = gs_get_render_target();
	gs_texture_t *mainTexture = obs_get_main_texture();

	if (target && target == mainTexture && p->mainRenderer.lastRenderedFrame() != frameTime &&
	    p->mainRenderer.wantsFrame(frameTime, obs_get_frame_interval_ns())) {
		p->mainRenderer.render(mainTexture, frameTime);
	}

	profile_end(kProfileCallback);
}

void removeRenderCallback()
{
	if (plugin && plugin->callbackRegistered) {
		/* Al volver, ningún callback nuestro está en ejecución: libobs los
		 * llama con draw_callbacks_mutex tomado. */
		obs_remove_main_rendered_callback(renderedCallback, nullptr);
		plugin->callbackRegistered = false;
	}
}

void frontendEvent(enum obs_frontend_event event, void *)
{
	if (event == OBS_FRONTEND_EVENT_EXIT) {
		removeRenderCallback();
		if (plugin && plugin->mainDock)
			plugin->mainDock->shutdown();
	}
}

} // namespace

bool obs_module_load(void)
{
	plugin = new Plugin();

	auto *mainDock = new nbp::PreviewDock(plugin->mainShared);
	plugin->mainDock = mainDock;
	if (!obs_frontend_add_dock_by_id(kDockMainId, obs_module_text("Dock.Main"), mainDock)) {
		obs_log(LOG_ERROR, "No se pudo añadir el dock «%s»", kDockMainId);
		delete mainDock;
	}

	obs_add_main_rendered_callback(renderedCallback, nullptr);
	plugin->callbackRegistered = true;
	obs_frontend_add_event_callback(frontendEvent, nullptr);

	obs_log(LOG_INFO, "plugin cargado (versión %s)", PLUGIN_VERSION);
	return true;
}

void obs_module_unload(void)
{
	if (!plugin)
		return;

	obs_frontend_remove_event_callback(frontendEvent, nullptr);
	removeRenderCallback();
	if (plugin->mainDock)
		plugin->mainDock->shutdown();

	/* El hilo gráfico ya está detenido; liberamos los recursos GL dentro del
	 * contexto, que es el único momento en que este código lo toma. */
	obs_enter_graphics();
	plugin->mainRenderer.destroy();
	plugin->scaler.destroy();
	obs_leave_graphics();

	os_unfair_lock_lock(&plugin->mainShared.lock);
	if (plugin->mainShared.latest)
		CFRelease(plugin->mainShared.latest);
	plugin->mainShared.latest = nullptr;
	os_unfair_lock_unlock(&plugin->mainShared.lock);

	obs_log(LOG_INFO, "plugin descargado (horizontal: %llu publicados, %llu sin superficie libre)",
		(unsigned long long)plugin->mainShared.framesPublished.load(),
		(unsigned long long)plugin->mainShared.framesSkippedBusy.load());

	delete plugin;
	plugin = nullptr;
}
