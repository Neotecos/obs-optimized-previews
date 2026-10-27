/*
Non-Blocking Previews — banco de pruebas del dock

Abre durante unos segundos una ventana Qt con un QDockWidget que contiene el
PreviewDock real, alimentado por libobs (OpenGL de OBS.app, sin interfaz de
OBS ni configuración del usuario) con un patrón animado. Comprueba que:
- el display link consume las superficies que publica el hilo gráfico;
- WindowServer marca como en uso la superficie mostrada (IOSurfaceIsInUse),
  que es en lo que se basa el anillo para no sobrescribirla;
- el anillo casi nunca se queda sin superficies libres;
- todo sigue funcionando tras desacoplar el dock (Qt recrea el NSView).

Uso: nbp-dock-test
*/

#include "preview-coordinator.hpp"
#include "preview-dock.hpp"

#include <obs.h>
#include <graphics/vec4.h>
#include <util/platform.h>

#include <QApplication>
#include <QDockWidget>
#include <QLabel>
#include <QMainWindow>
#include <QScreen>
#include <QTimer>

#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>

#include <cstdio>

/* preview-dock.mm traduce textos con obs_module_text(); aquí no hay módulo. */
extern "C" const char *obs_module_text(const char *lookup)
{
	return lookup;
}

namespace {

nbp::PreviewCoordinator coordinator;
int failures = 0;

void check(bool condition, const char *what)
{
	printf("[%s] %s\n", condition ? " OK " : "FALLO", what);
	if (!condition)
		failures++;
}

/* Colores que cambian cada fotograma para que se vea movimiento. */
void drawPattern(void *, uint32_t cx, uint32_t cy)
{
	static uint32_t frame = 0;
	const float phase = float(frame++ % 120) / 120.0f;

	gs_effect_t *solid = obs_get_base_effect(OBS_EFFECT_SOLID);
	struct vec4 color;
	vec4_set(&color, phase, 0.3f, 1.0f - phase, 1.0f);
	gs_effect_set_vec4(gs_effect_get_param_by_name(solid, "color"), &color);
	while (gs_effect_loop(solid, "Solid"))
		gs_draw_sprite(nullptr, 0, cx, cy);

	vec4_set(&color, 1.0f, 1.0f, 1.0f, 1.0f);
	gs_effect_set_vec4(gs_effect_get_param_by_name(solid, "color"), &color);
	gs_matrix_push();
	gs_matrix_translate3f(phase * float(cx - cx / 8), float(cy / 2 - cy / 16), 0.0f);
	while (gs_effect_loop(solid, "Solid"))
		gs_draw_sprite(nullptr, 0, cx / 8, cy / 8);
	gs_matrix_pop();
}

void beforeRender(void *, uint32_t, uint32_t)
{
	coordinator.onBeforeRender();
}

void rendered(void *)
{
	coordinator.onRendered();
}

} // namespace

int main(int argc, char **argv)
{
	QCoreApplication::addLibraryPath("/Applications/OBS.app/Contents/PlugIns");
	QApplication app(argc, argv);

	if (!obs_startup("en-US", nullptr, nullptr))
		return 2;

	struct obs_video_info ovi = {};
	ovi.graphics_module = "/Applications/OBS.app/Contents/Frameworks/libobs-opengl.dylib";
	ovi.fps_num = 60;
	ovi.fps_den = 1;
	ovi.base_width = 2560;
	ovi.base_height = 1440;
	ovi.output_width = 2560;
	ovi.output_height = 1440;
	ovi.output_format = VIDEO_FORMAT_NV12;
	ovi.gpu_conversion = true;
	ovi.colorspace = VIDEO_CS_709;
	ovi.range = VIDEO_RANGE_PARTIAL;
	ovi.scale_type = OBS_SCALE_BICUBIC;
	if (obs_reset_video(&ovi) != OBS_VIDEO_SUCCESS) {
		obs_shutdown();
		return 2;
	}

	obs_add_main_render_callback(drawPattern, nullptr);
	obs_add_main_render_callback(beforeRender, nullptr);
	obs_add_main_rendered_callback(rendered, nullptr);

	QMainWindow window;
	window.setWindowTitle("nbp-dock-test");
	window.setCentralWidget(new QLabel("Non-Blocking Previews — prueba del dock"));
	auto *dockWidget = new QDockWidget("Previsualización (prueba)", &window);
	auto *preview = new nbp::PreviewDock(coordinator.mainShared);
	dockWidget->setWidget(preview);
	window.addDockWidget(Qt::LeftDockWidgetArea, dockWidget);
	window.resize(1200, 700);
	window.show();
	/* Lanzada desde un terminal la app no queda en primer plano, y macOS oculta
	 * los docks flotantes (ventanas auxiliares) de una app inactiva: el plugin
	 * dejaría de dibujar, que es lo correcto, pero no es lo que se prueba. */
	[NSApp activateIgnoringOtherApps:YES];

	int samples = 0;
	int displayedSamples = 0;
	int inUseSamples = 0;
	QTimer sampler;
	QObject::connect(&sampler, &QTimer::timeout, [&]() {
		os_unfair_lock_lock(&coordinator.mainShared.lock);
		IOSurfaceRef displayed = coordinator.mainShared.displayed;
		const bool inUse = displayed && IOSurfaceIsInUse(displayed);
		os_unfair_lock_unlock(&coordinator.mainShared.lock);
		samples++;
		displayedSamples += displayed ? 1 : 0;
		inUseSamples += inUse ? 1 : 0;
	});
	sampler.start(50);

	uint64_t publishedAtFloat = 0;
	uint32_t dockedWidth = 0, dockedHeight = 0;
	QTimer::singleShot(4000, [&]() {
		const uint64_t size = coordinator.mainShared.requestedSize.load();
		dockedWidth = nbp::PreviewShared::unpackWidth(size);
		dockedHeight = nbp::PreviewShared::unpackHeight(size);
		publishedAtFloat = coordinator.mainShared.framesPublished.load();
		dockWidget->setFloating(true);
		dockWidget->resize(800, 500);
		[NSApp activateIgnoringOtherApps:YES];
		dockWidget->activateWindow();
		QTimer::singleShot(500, [dockWidget, preview]() {
			const QRect g = dockWidget->geometry();
			const QRect screen = dockWidget->screen() ? dockWidget->screen()->availableGeometry() : QRect();
			printf("dock flotante en %d,%d %dx%d; pantalla %d,%d %dx%d; visible=%d; preview visible=%d %dx%d\n",
			       g.x(), g.y(), g.width(), g.height(), screen.x(), screen.y(), screen.width(),
			       screen.height(), dockWidget->isVisible(), preview->isVisible(), preview->width(),
			       preview->height());
		});
	});

	QTimer::singleShot(8000, [&]() {
		sampler.stop();
		const uint64_t published = coordinator.mainShared.framesPublished.load();
		const uint64_t busy = coordinator.mainShared.framesSkippedBusy.load();
		const uint64_t size = coordinator.mainShared.requestedSize.load();

		printf("tamaño pedido acoplado: %ux%u px; desacoplado: %ux%u px\n", dockedWidth, dockedHeight,
		       nbp::PreviewShared::unpackWidth(size), nbp::PreviewShared::unpackHeight(size));
		printf("publicados: %llu (tras desacoplar: %llu); sin superficie libre: %llu\n",
		       (unsigned long long)published, (unsigned long long)(published - publishedAtFloat),
		       (unsigned long long)busy);
		printf("muestras: %d; con superficie mostrada: %d; en uso por WindowServer: %d\n", samples,
		       displayedSamples, inUseSamples);
		const uint64_t latencyCount = coordinator.mainShared.latencyCount.load();
		const double latencyMs =
			latencyCount ? double(coordinator.mainShared.latencySumNs.load()) / double(latencyCount) / 1e6 : 0;
		const double latencyMaxMs = double(coordinator.mainShared.latencyMaxNs.load()) / 1e6;
		printf("latencia hasta Core Animation: media %.1f ms, máxima %.1f ms\n", latencyMs, latencyMaxMs);
		printf("entregados a Core Animation: %llu; sustituidos antes de mostrarse: %llu; huecos >1,5 fotogramas: %llu\n",
		       (unsigned long long)coordinator.mainShared.framesPresented.load(),
		       (unsigned long long)coordinator.mainShared.framesSuperseded.load(),
		       (unsigned long long)coordinator.mainShared.presentGaps.load());
		check(latencyMs > 0.0 && latencyMs < 25.0, "latencia media por debajo de 1,5 fotogramas (25 ms)");

		check(dockedWidth > 0 && dockedHeight > 0, "el dock acoplado pide un tamaño en píxeles");
		/* Acoplado, la ventana principal está visible los 4 s (~240 fotogramas).
		 * Desacoplado, macOS oculta o tapa la ventana flotante en cuanto otra app
		 * pasa a primer plano y el plugin deja de dibujar, que es lo correcto: se
		 * comprueba que vuelve a engancharse, no que siga visible. */
		check(publishedAtFloat > 200, "se publican fotogramas de forma continua (~60/s)");
		check(published - publishedAtFloat > 20, "vuelve a publicar tras desacoplar el dock");
		check(displayedSamples > samples * 8 / 10, "el display link pone superficies en la capa");
		check(inUseSamples > displayedSamples / 2, "WindowServer marca en uso la superficie mostrada");
		check(busy * 50 < published, "el anillo casi nunca se queda sin superficies (<2 %)");

		preview->shutdown();
		app.quit();
	});

	app.exec();

	obs_remove_main_rendered_callback(rendered, nullptr);
	obs_remove_main_render_callback(beforeRender, nullptr);
	obs_remove_main_render_callback(drawPattern, nullptr);

	obs_enter_graphics();
	coordinator.destroyGraphics();
	obs_leave_graphics();
	coordinator.releasePublished();
	obs_shutdown();

	printf("%s (%d fallos)\n", failures ? "PRUEBA FALLIDA" : "PRUEBA SUPERADA", failures);
	return failures ? 1 : 0;
}
