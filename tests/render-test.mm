/*
Non-Blocking Previews — banco de pruebas del hilo gráfico

Arranca libobs con el módulo OpenGL de OBS.app (sin interfaz, sin perfiles
ni configuración del usuario), pinta patrones conocidos en el lienzo
principal y en un canvas vertical de prueba, y comprueba que
PreviewCoordinator publica IOSurfaces correctas: orientación, color (sRGB),
identificación del canvas vertical, redimensionado, video_reset, límite de
FPS, retirada del canvas y coste por callback en el hilo gráfico.

Uso: nbp-render-test [ruta/a/libobs-opengl.dylib]
*/

#include "preview-coordinator.hpp"
#include "preview-shared.hpp"

#include <obs.h>
#include <graphics/matrix4.h>
#include <graphics/vec4.h>
#include <util/platform.h>

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

constexpr uint32_t kCanvasWidth = 2560;
constexpr uint32_t kCanvasHeight = 1440;

nbp::PreviewCoordinator coordinator;

/* Solo hilo gráfico mientras el callback está registrado. */
bool collecting = false;
std::vector<uint64_t> callbackNs;

int failures = 0;

void check(bool condition, const char *what)
{
	printf("[%s] %s\n", condition ? " OK " : "FALLO", what);
	if (!condition)
		failures++;
}

void fill(gs_effect_t *solid, float r, float g, float b, float y, uint32_t cx, uint32_t cy)
{
	struct vec4 color;
	vec4_set(&color, r, g, b, 1.0f);
	gs_effect_set_vec4(gs_effect_get_param_by_name(solid, "color"), &color);
	gs_matrix_push();
	gs_matrix_translate3f(0.0f, y, 0.0f);
	while (gs_effect_loop(solid, "Solid"))
		gs_draw_sprite(nullptr, 0, cx, cy);
	gs_matrix_pop();
}

/* Mezclas en orden de render: 0 = principal, 1 = señuelo, 2 = vertical. */
bool decoyActive = false;
uint64_t patternFrame = 0;
int patternIndex = 0;

/* Se ejecuta al principio de cada mezcla. Lienzo horizontal: franjas roja,
 * gris 50 % y azul. Lienzo vertical: mitad superior verde, inferior magenta.
 * Señuelo (otra vista del mismo tamaño que el vertical): amarillo. */
void drawPattern(void *, uint32_t cx, uint32_t cy)
{
	const uint64_t frame = obs_get_video_frame_time();
	if (frame != patternFrame) {
		patternFrame = frame;
		patternIndex = 0;
	}
	const int index = patternIndex++;

	gs_effect_t *solid = obs_get_base_effect(OBS_EFFECT_SOLID);
	if (cy > cx && decoyActive && index == 1) {
		fill(solid, 1.0f, 1.0f, 0.0f, 0.0f, cx, cy);
		return;
	}
	if (cy > cx) {
		fill(solid, 0.0f, 1.0f, 0.0f, 0.0f, cx, cy / 2);
		fill(solid, 1.0f, 0.0f, 1.0f, float(cy / 2), cx, cy - cy / 2);
		return;
	}

	const uint32_t band = cy / 3;
	fill(solid, 1.0f, 0.0f, 0.0f, 0.0f, cx, band);
	fill(solid, 0.5f, 0.5f, 0.5f, float(band), cx, band);
	fill(solid, 0.0f, 0.0f, 1.0f, float(2 * band), cx, cy - 2 * band);
}

void beforeRender(void *, uint32_t, uint32_t)
{
	coordinator.onBeforeRender();
}

void rendered(void *)
{
	const uint64_t start = os_gettime_ns();
	coordinator.onRendered();
	if (collecting)
		callbackNs.push_back(os_gettime_ns() - start);
}

/* Hace lo mismo que el display link del dock: toma la última superficie. */
struct Consumer {
	nbp::PreviewShared &shared;
	IOSurfaceRef current = nullptr;
	uint64_t seenSerial = 0;

	void consume()
	{
		IOSurfaceRef next = nullptr;
		os_unfair_lock_lock(&shared.lock);
		if (shared.latestSerial != seenSerial) {
			seenSerial = shared.latestSerial;
			next = shared.latest;
			if (next) {
				CFRetain(next);
				shared.displayed = next;
			}
		}
		os_unfair_lock_unlock(&shared.lock);

		if (next) {
			if (current)
				CFRelease(current);
			current = next;
		}
	}

	void release()
	{
		if (current)
			CFRelease(current);
		current = nullptr;
	}

	uint32_t width() const { return current ? uint32_t(IOSurfaceGetWidth(current)) : 0; }
	uint32_t height() const { return current ? uint32_t(IOSurfaceGetHeight(current)) : 0; }
};

Consumer mainConsumer{coordinator.mainShared};
Consumer verticalConsumer{coordinator.verticalShared};

void runFor(double seconds)
{
	const uint64_t end = os_gettime_ns() + uint64_t(seconds * 1e9);
	while (os_gettime_ns() < end) {
		mainConsumer.consume();
		verticalConsumer.consume();
		os_sleep_ms(7);
	}
}

struct Pixel {
	uint8_t b, g, r, a;
};

Pixel readPixel(IOSurfaceRef surface, uint32_t x, uint32_t y)
{
	Pixel pixel{};
	IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
	const auto *base = static_cast<const uint8_t *>(IOSurfaceGetBaseAddress(surface));
	const size_t stride = IOSurfaceGetBytesPerRow(surface);
	memcpy(&pixel, base + y * stride + x * 4, sizeof(pixel));
	IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
	return pixel;
}

bool near(int value, int expected, int tolerance)
{
	return abs(value - expected) <= tolerance;
}

void printPixel(const char *label, const Pixel &p)
{
	printf("  %s BGRA=%u,%u,%u,%u\n", label, p.b, p.g, p.r, p.a);
}

void printStats(const char *name, std::vector<uint64_t> values)
{
	if (values.empty()) {
		printf("%s: sin muestras\n", name);
		return;
	}
	std::sort(values.begin(), values.end());
	auto at = [&](double q) { return double(values[size_t(q * double(values.size() - 1))]) / 1000.0; };
	printf("%s: n=%zu  p50=%.1f µs  p90=%.1f µs  p99=%.1f µs  máx=%.1f µs\n", name, values.size(), at(0.5),
	       at(0.9), at(0.99), double(values.back()) / 1000.0);
}

void waitCallbacks(uint64_t count)
{
	const uint64_t target = coordinator.graphicsCallbacks.load() + count;
	while (coordinator.graphicsCallbacks.load() < target)
		os_sleep_ms(1);
}

struct obs_video_info videoInfo(uint32_t width, uint32_t height, const char *glModule)
{
	struct obs_video_info ovi = {};
	ovi.graphics_module = glModule;
	ovi.fps_num = 60;
	ovi.fps_den = 1;
	ovi.base_width = width;
	ovi.base_height = height;
	ovi.output_width = width;
	ovi.output_height = height;
	ovi.output_format = VIDEO_FORMAT_NV12;
	ovi.gpu_conversion = true;
	ovi.colorspace = VIDEO_CS_709;
	ovi.range = VIDEO_RANGE_PARTIAL;
	ovi.scale_type = OBS_SCALE_BICUBIC;
	return ovi;
}

} // namespace

int main(int argc, char **argv)
{
	@autoreleasepool {
		const char *glModule = argc > 1 ? argv[1] : "/Applications/OBS.app/Contents/Frameworks/libobs-opengl.dylib";

		if (!obs_startup("en-US", nullptr, nullptr)) {
			fprintf(stderr, "obs_startup falló\n");
			return 2;
		}

		struct obs_video_info ovi = videoInfo(kCanvasWidth, kCanvasHeight, glModule);
		const int reset = obs_reset_video(&ovi);
		if (reset != OBS_VIDEO_SUCCESS) {
			fprintf(stderr, "obs_reset_video falló (%d)\n", reset);
			obs_shutdown();
			return 2;
		}

		callbackNs.reserve(8192);
		obs_add_main_render_callback(drawPattern, nullptr);
		obs_add_main_render_callback(beforeRender, nullptr);
		obs_add_main_rendered_callback(rendered, nullptr);

		/* 1. Horizontal: dock de 1280×720 px. */
		printf("--- horizontal ---\n");
		coordinator.mainShared.requestedSize.store(nbp::PreviewShared::packSize(1280, 720));
		runFor(1.5);
		check(mainConsumer.current != nullptr, "se publica al menos una superficie");
		if (mainConsumer.current) {
			const uint32_t w = mainConsumer.width(), h = mainConsumer.height();
			check(w == 1280 && h == 720, "tamaño ajustado al dock (1280x720)");
			const Pixel top = readPixel(mainConsumer.current, w / 2, h / 6);
			const Pixel middle = readPixel(mainConsumer.current, w / 2, h / 2);
			const Pixel bottom = readPixel(mainConsumer.current, w / 2, h * 5 / 6);
			printPixel("arriba", top);
			printPixel("centro", middle);
			printPixel("abajo", bottom);
			check(top.r > 240 && top.g < 16 && top.b < 16, "franja superior roja (orientación correcta)");
			check(bottom.b > 240 && bottom.r < 16 && bottom.g < 16, "franja inferior azul");
			check(near(middle.r, 128, 2) && near(middle.g, 128, 2) && near(middle.b, 128, 2),
			      "gris 50 % conserva su valor (sin doble conversión sRGB)");
			check(top.a == 255, "alfa opaco");
		}

		/* 2. Canvas vertical de prueba (como el de Vertical Canvas). El
		 *    test conserva la referencia fuerte, igual que CanvasTracker.
		 *    Antes se crea un señuelo: otra vista de 1080x1920 con otro
		 *    contenido (como la de Source Record), que se renderiza antes. */
		printf("--- vertical ---\n");
		struct obs_video_info verticalOvi = videoInfo(1080, 1920, glModule);
		obs_view_t *decoyView = obs_view_create();
		check(obs_view_add2(decoyView, &verticalOvi) != nullptr, "señuelo de 1080x1920 creado");
		decoyActive = true;
		obs_canvas_t *vertical = obs_canvas_create("NBP Test Vertical", &verticalOvi, DEVICE);
		check(vertical != nullptr, "canvas vertical creado");
		coordinator.verticalShared.requestedSize.store(nbp::PreviewShared::packSize(540, 1200));
		coordinator.verticalCanvas.store(vertical);
		coordinator.relearnVertical.store(true);
		runFor(1.5);
		check(verticalConsumer.current != nullptr, "se publica la previsualización vertical");
		if (verticalConsumer.current) {
			const uint32_t w = verticalConsumer.width(), h = verticalConsumer.height();
			printf("  superficie %ux%u\n", w, h);
			check(w == 540 && h == 960, "tamaño vertical ajustado (540x960)");
			const Pixel top = readPixel(verticalConsumer.current, w / 2, h / 4);
			const Pixel bottom = readPixel(verticalConsumer.current, w / 2, h * 3 / 4);
			printPixel("arriba", top);
			printPixel("abajo", bottom);
			check(top.g > 240 && top.r < 16 && top.b < 16,
			      "la vertical muestra su propio canvas (verde arriba), ni el principal ni el señuelo");
			check(bottom.r > 240 && bottom.b > 240 && bottom.g < 16, "vertical: magenta abajo");
		}

		/* 3. Coste en régimen estable con las dos previsualizaciones. */
		printf("--- coste con las dos previsualizaciones ---\n");
		runFor(0.5);
		const uint64_t mainBefore = coordinator.mainShared.framesPublished.load();
		const uint64_t verticalBefore = coordinator.verticalShared.framesPublished.load();
		collecting = true;
		runFor(10.0);
		collecting = false;
		const uint64_t mainPublished = coordinator.mainShared.framesPublished.load() - mainBefore;
		const uint64_t verticalPublished = coordinator.verticalShared.framesPublished.load() - verticalBefore;
		printf("  publicados en 10 s: horizontal %llu, vertical %llu\n", (unsigned long long)mainPublished,
		       (unsigned long long)verticalPublished);
		check(mainPublished >= 580 && verticalPublished >= 580, "ambas a ~60 FPS");
		printStats("  callback (todas las mezclas)", callbackNs);

		/* 4. video_reset del canvas vertical con aviso (como la señal). */
		printf("--- video_reset ---\n");
		struct obs_video_info squareOvi = videoInfo(1080, 1350, glModule);
		check(obs_canvas_reset_video(vertical, &squareOvi), "canvas vertical a 1080x1350");
		coordinator.relearnVertical.store(true);
		runFor(1.0);
		printf("  superficie %ux%u\n", verticalConsumer.width(), verticalConsumer.height());
		check(verticalConsumer.width() == 540 && verticalConsumer.height() == 675,
		      "tras video_reset se sigue la nueva textura (540x675)");

		/* 5. video_reset sin aviso: la reidentificación periódica lo cubre. */
		check(obs_canvas_reset_video(vertical, &verticalOvi), "canvas vertical a 1080x1920 sin aviso");
		runFor(6.0);
		printf("  superficie %ux%u\n", verticalConsumer.width(), verticalConsumer.height());
		check(verticalConsumer.width() == 540 && verticalConsumer.height() == 960,
		      "la reidentificación periódica recupera la vertical");

		/* 6. Límite de 30 FPS en la horizontal. */
		printf("--- límites ---\n");
		const uint64_t before30 = coordinator.mainShared.framesPublished.load();
		coordinator.mainShared.fpsLimit.store(30);
		runFor(2.0);
		const uint64_t published30 = coordinator.mainShared.framesPublished.load() - before30;
		printf("  publicados en 2 s a 30 FPS: %llu\n", (unsigned long long)published30);
		check(published30 >= 50 && published30 <= 64, "límite de 30 FPS respetado");
		coordinator.mainShared.fpsLimit.store(0);

		/* 7. Oculta: no se publica nada. */
		const uint64_t hiddenBefore = coordinator.mainShared.framesPublished.load();
		coordinator.mainShared.requestedSize.store(0);
		runFor(0.5);
		check(coordinator.mainShared.framesPublished.load() - hiddenBefore <= 1, "sin dibujar mientras está oculta");

		/* 8. Retirada del canvas: el hilo principal publica nullptr, espera
		 *    a que avance el contador de callbacks y solo entonces suelta la
		 *    referencia (lo que hace CanvasTracker). */
		printf("--- retirada ---\n");
		coordinator.verticalCanvas.store(nullptr);
		waitCallbacks(2);
		obs_canvas_remove(vertical);
		obs_canvas_release(vertical);
		const uint64_t retiredBefore = coordinator.verticalShared.framesPublished.load();
		runFor(0.5);
		check(coordinator.verticalShared.framesPublished.load() - retiredBefore <= 1,
		      "sin canvas vertical no se dibuja nada");

		obs_remove_main_rendered_callback(rendered, nullptr);
		obs_remove_main_render_callback(beforeRender, nullptr);
		obs_remove_main_render_callback(drawPattern, nullptr);
		obs_view_remove(decoyView);
		obs_view_destroy(decoyView);

		printf("sin superficie libre: horizontal %llu, vertical %llu\n",
		       (unsigned long long)coordinator.mainShared.framesSkippedBusy.load(),
		       (unsigned long long)coordinator.verticalShared.framesSkippedBusy.load());

		obs_enter_graphics();
		coordinator.destroyGraphics();
		obs_leave_graphics();
		mainConsumer.release();
		verticalConsumer.release();
		coordinator.releasePublished();

		obs_shutdown();

		printf("%s (%d fallos)\n", failures ? "PRUEBA FALLIDA" : "PRUEBA SUPERADA", failures);
		return failures ? 1 : 0;
	}
}
