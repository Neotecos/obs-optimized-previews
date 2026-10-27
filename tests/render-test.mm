/*
Non-Blocking Previews — banco de pruebas del renderizador

Arranca libobs con el módulo OpenGL de OBS.app (sin interfaz, sin perfiles
ni configuración del usuario), pinta un patrón conocido en el lienzo principal
y comprueba que PreviewRenderer publica IOSurfaces correctas: orientación,
color (sRGB), redimensionado, rotación del anillo y coste por fotograma en el
hilo gráfico.

Uso: nbp-render-test [ruta/a/libobs-opengl.dylib]
*/

#include "gl-scaler.hpp"
#include "preview-renderer.hpp"
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

nbp::GlScaler scaler;
nbp::PreviewShared shared;
nbp::PreviewRenderer renderer(shared, scaler, "nbp_test_preview");

/* Solo hilo gráfico mientras el callback está registrado. */
std::vector<uint64_t> callbackNs;
std::vector<uint64_t> renderNs;
uint64_t mainMatches = 0;

/* Fase estable: tiempos por paso, sin los fotogramas que recrean superficies. */
bool collectSteps = false;
struct StepSamples {
	std::vector<uint64_t> callback, poll, acquire, draw, fence;
} steps;

int failures = 0;

void check(bool condition, const char *what)
{
	printf("[%s] %s\n", condition ? " OK " : "FALLO", what);
	if (!condition)
		failures++;
}

/* Tres franjas horizontales: rojo (arriba), gris 50 % (centro), azul (abajo). */
void drawPattern(void *, uint32_t cx, uint32_t cy)
{
	gs_effect_t *solid = obs_get_base_effect(OBS_EFFECT_SOLID);
	gs_eparam_t *color = gs_effect_get_param_by_name(solid, "color");
	const uint32_t band = cy / 3;

	const struct vec4 colors[3] = {
		{{{1.0f, 0.0f, 0.0f, 1.0f}}},
		{{{0.5f, 0.5f, 0.5f, 1.0f}}},
		{{{0.0f, 0.0f, 1.0f, 1.0f}}},
	};

	for (int i = 0; i < 3; i++) {
		gs_effect_set_vec4(color, &colors[i]);
		gs_matrix_push();
		gs_matrix_translate3f(0.0f, float(band * uint32_t(i)), 0.0f);
		while (gs_effect_loop(solid, "Solid"))
			gs_draw_sprite(nullptr, 0, cx, i == 2 ? cy - 2 * band : band);
		gs_matrix_pop();
	}
}

/* Misma lógica que el plugin para el lienzo principal. */
void rendered(void *)
{
	const uint64_t start = os_gettime_ns();

	renderer.lastTiming = {};
	renderer.poll();

	const uint64_t frameTime = obs_get_video_frame_time();
	gs_texture_t *target = gs_get_render_target();
	gs_texture_t *mainTexture = obs_get_main_texture();

	if (target && target == mainTexture && renderer.lastRenderedFrame() != frameTime &&
	    renderer.wantsFrame(frameTime, obs_get_frame_interval_ns())) {
		mainMatches++;
		const uint64_t renderStart = os_gettime_ns();
		renderer.render(mainTexture, frameTime);
		renderNs.push_back(os_gettime_ns() - renderStart);
	}

	const uint64_t total = os_gettime_ns() - start;
	callbackNs.push_back(total);

	const auto &t = renderer.lastTiming;
	if (collectSteps && t.recreate == 0) {
		steps.callback.push_back(total);
		steps.poll.push_back(t.poll);
		steps.acquire.push_back(t.acquire);
		steps.draw.push_back(t.draw);
		steps.fence.push_back(t.fence);
	}
}

void runFor(double seconds);

void runSteady(uint32_t width, uint32_t height, double seconds)
{
	shared.requestedSize.store(nbp::PreviewShared::packSize(width, height));
	runFor(0.5); /* recreación y calentamiento */
	steps = {};
	collectSteps = true;
	runFor(seconds);
	collectSteps = false;
	runFor(0.05);
}

/* Hace lo mismo que el display link del dock: toma la última superficie. */
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

void runFor(double seconds)
{
	const uint64_t end = os_gettime_ns() + uint64_t(seconds * 1e9);
	while (os_gettime_ns() < end) {
		consume();
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

void printStats(const char *name, std::vector<uint64_t> values)
{
	if (values.empty()) {
		printf("%s: sin muestras\n", name);
		return;
	}
	std::sort(values.begin(), values.end());
	auto at = [&](double q) { return double(values[size_t(q * double(values.size() - 1))]) / 1000.0; };
	printf("%s: n=%zu  p50=%.1f µs  p99=%.1f µs  máx=%.1f µs\n", name, values.size(), at(0.5), at(0.99),
	       double(values.back()) / 1000.0);
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

		struct obs_video_info ovi = {};
		ovi.graphics_module = glModule;
		ovi.fps_num = 60;
		ovi.fps_den = 1;
		ovi.base_width = kCanvasWidth;
		ovi.base_height = kCanvasHeight;
		ovi.output_width = kCanvasWidth;
		ovi.output_height = kCanvasHeight;
		ovi.output_format = VIDEO_FORMAT_NV12;
		ovi.gpu_conversion = true;
		ovi.colorspace = VIDEO_CS_709;
		ovi.range = VIDEO_RANGE_PARTIAL;
		ovi.scale_type = OBS_SCALE_BICUBIC;

		const int reset = obs_reset_video(&ovi);
		if (reset != OBS_VIDEO_SUCCESS) {
			fprintf(stderr, "obs_reset_video falló (%d)\n", reset);
			obs_shutdown();
			return 2;
		}

		callbackNs.reserve(4096);
		renderNs.reserve(4096);

		obs_add_main_render_callback(drawPattern, nullptr);
		obs_add_main_rendered_callback(rendered, nullptr);

		/* 1. Dock de 1280×720 px: superficie a mitad de tamaño. */
		shared.requestedSize.store(nbp::PreviewShared::packSize(1280, 720));
		runFor(2.0);

		check(current != nullptr, "se publica al menos una superficie");
		if (current) {
			const uint32_t w = uint32_t(IOSurfaceGetWidth(current));
			const uint32_t h = uint32_t(IOSurfaceGetHeight(current));
			printf("superficie %ux%u\n", w, h);
			check(w == 1280 && h == 720, "tamaño ajustado al dock (1280x720)");

			const Pixel top = readPixel(current, w / 2, h / 6);
			const Pixel middle = readPixel(current, w / 2, h / 2);
			const Pixel bottom = readPixel(current, w / 2, h * 5 / 6);
			printf("arriba BGRA=%u,%u,%u,%u  centro=%u,%u,%u,%u  abajo=%u,%u,%u,%u\n", top.b, top.g, top.r,
			       top.a, middle.b, middle.g, middle.r, middle.a, bottom.b, bottom.g, bottom.r, bottom.a);
			check(top.r > 240 && top.g < 16 && top.b < 16, "franja superior roja (orientación correcta)");
			check(bottom.b > 240 && bottom.r < 16 && bottom.g < 16, "franja inferior azul");
			check(near(middle.r, 128, 2) && near(middle.g, 128, 2) && near(middle.b, 128, 2),
			      "gris 50 % conserva su valor (sin doble conversión sRGB)");
			check(top.a == 255, "alfa opaco");
		}

		/* 2. Dock más alto que ancho: la superficie mantiene 16:9. */
		shared.requestedSize.store(nbp::PreviewShared::packSize(640, 900));
		runFor(1.0);
		if (current) {
			const uint32_t w = uint32_t(IOSurfaceGetWidth(current));
			const uint32_t h = uint32_t(IOSurfaceGetHeight(current));
			printf("superficie tras redimensionar %ux%u\n", w, h);
			check(w == 640 && h == 360, "redimensionado con proporción del lienzo (640x360)");
		}

		/* 3. Dock enorme: nunca más grande que el lienzo. */
		shared.requestedSize.store(nbp::PreviewShared::packSize(5120, 2880));
		runFor(1.0);
		if (current) {
			const uint32_t w = uint32_t(IOSurfaceGetWidth(current));
			const uint32_t h = uint32_t(IOSurfaceGetHeight(current));
			check(w == kCanvasWidth && h == kCanvasHeight, "limitado al tamaño del lienzo (2560x1440)");
		}

		/* 4. Límite de 30 FPS. */
		const uint64_t publishedBefore = shared.framesPublished.load();
		shared.fpsLimit.store(30);
		runFor(2.0);
		const uint64_t published30 = shared.framesPublished.load() - publishedBefore;
		printf("publicados en 2 s a 30 FPS: %llu\n", (unsigned long long)published30);
		check(published30 >= 50 && published30 <= 64, "límite de 30 FPS respetado");
		shared.fpsLimit.store(0);

		/* 5. Oculto: no se dibuja nada. */
		const size_t rendersBefore = renderNs.size();
		shared.requestedSize.store(0);
		runFor(0.5);
		check(renderNs.size() == rendersBefore, "sin dibujar mientras está oculto");

		/* 6. Fase estable para medir coste por paso. */
		const uint32_t sizes[][2] = {{1280, 720}, {2560, 1440}};
		for (const auto &size : sizes) {
			runSteady(size[0], size[1], 5.0);
			printf("--- fase estable %ux%u ---\n", size[0], size[1]);
			printStats("  callback", steps.callback);
			printStats("  poll", steps.poll);
			printStats("  acquire", steps.acquire);
			printStats("  draw (shader)", steps.draw);
			printStats("  fence", steps.fence);
		}
		shared.requestedSize.store(0);
		runFor(0.1);

		obs_remove_main_rendered_callback(rendered, nullptr);
		obs_remove_main_render_callback(drawPattern, nullptr);

		printf("publicados=%llu  sin superficie libre=%llu  coincidencias lienzo principal=%llu\n",
		       (unsigned long long)shared.framesPublished.load(),
		       (unsigned long long)shared.framesSkippedBusy.load(), (unsigned long long)mainMatches);
		printStats("callback completo", callbackNs);
		printStats("render (dibujo+fence)", renderNs);

		obs_enter_graphics();
		renderer.destroy();
		scaler.destroy();
		obs_leave_graphics();

		if (current)
			CFRelease(current);
		if (shared.latest)
			CFRelease(shared.latest);

		obs_shutdown();

		printf("%s (%d fallos)\n", failures ? "PRUEBA FALLIDA" : "PRUEBA SUPERADA", failures);
		return failures ? 1 : 0;
	}
}
