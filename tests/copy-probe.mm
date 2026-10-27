/*
Non-Blocking Previews — sonda de coste de copia en el hilo gráfico

Mide, en un contexto OpenGL real de OBS (libobs-opengl de OBS.app), el coste
de CPU en el hilo gráfico de varias formas de llevar una textura de libobs a
otra textura:
  A) glBlitFramebuffer a una textura GL normal
  B) glBlitFramebuffer a una textura respaldada por IOSurface
  C) dibujo con un shader propio sobre una IOSurface
  D) glCopyTexSubImage2D a una IOSurface
  E) dibujo con libobs a una textura intermedia (referencia)

Uso: nbp-copy-probe [ancho alto]
*/

#include <obs.h>
#include <graphics/vec4.h>
#include <util/platform.h>

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <OpenGL/gl3.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <vector>

namespace {

constexpr int kRing = 4;
uint32_t width = 1280;
uint32_t height = 720;

struct Target {
	IOSurfaceRef surface = nullptr;
	gs_texture_t *texture = nullptr;
	GLuint fbo = 0;
	GLenum glTarget = GL_TEXTURE_2D;
};

bool ready = false;
bool collecting = false;
gs_texture_t *staging = nullptr;
GLuint stagingFbo = 0;
std::array<Target, kRing> plain, surfaceBlit, surfaceDraw, surfaceCopy;
GLuint program = 0, vao = 0;
GLint samplerLocation = -1;
int frame = 0;

std::vector<uint64_t> samplesA, samplesB, samplesC, samplesD, samplesE;

GLuint name(gs_texture_t *texture)
{
	return *static_cast<GLuint *>(gs_texture_get_obj(texture));
}

IOSurfaceRef makeSurface()
{
	NSDictionary *properties = @{
		(id)kIOSurfaceWidth: @(width),
		(id)kIOSurfaceHeight: @(height),
		(id)kIOSurfaceBytesPerElement: @4,
		(id)kIOSurfaceBytesPerRow: @(IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)),
		(id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
	};
	return IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}

void attach(Target &target)
{
	glGenFramebuffers(1, &target.fbo);
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target.fbo);
	glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target.glTarget, name(target.texture), 0);
}

GLuint compile(GLenum type, const char *source)
{
	GLuint shader = glCreateShader(type);
	glShaderSource(shader, 1, &source, nullptr);
	glCompileShader(shader);
	return shader;
}

void setup()
{
	GLint read = 0, draw = 0;
	glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);

	staging = gs_texture_create(width, height, GS_BGRA, 1, nullptr, GS_RENDER_TARGET);
	glGenFramebuffers(1, &stagingFbo);
	glBindFramebuffer(GL_READ_FRAMEBUFFER, stagingFbo);
	glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, name(staging), 0);

	for (int i = 0; i < kRing; i++) {
		plain[i].texture = gs_texture_create(width, height, GS_BGRA, 1, nullptr, GS_RENDER_TARGET);
		attach(plain[i]);

		for (auto *ring : {&surfaceBlit, &surfaceDraw, &surfaceCopy}) {
			Target &t = (*ring)[i];
			t.surface = makeSurface();
			t.texture = gs_texture_create_from_iosurface(t.surface);
			t.glTarget = GL_TEXTURE_RECTANGLE;
			attach(t);
		}
	}

	const char *vs = "#version 330 core\n"
			 "void main() {\n"
			 "  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);\n"
			 "  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
			 "}\n";
	const char *fs = "#version 330 core\n"
			 "uniform sampler2D image;\n"
			 "out vec4 color;\n"
			 "void main() { color = texelFetch(image, ivec2(gl_FragCoord.xy), 0); }\n";
	program = glCreateProgram();
	glAttachShader(program, compile(GL_VERTEX_SHADER, vs));
	glAttachShader(program, compile(GL_FRAGMENT_SHADER, fs));
	glLinkProgram(program);
	samplerLocation = glGetUniformLocation(program, "image");
	glGenVertexArrays(1, &vao);

	glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(read));
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(draw));
	ready = true;
}

void blitTo(const Target &target)
{
	glBindFramebuffer(GL_READ_FRAMEBUFFER, stagingFbo);
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target.fbo);
	glBlitFramebuffer(0, 0, GLint(width), GLint(height), 0, 0, GLint(width), GLint(height), GL_COLOR_BUFFER_BIT,
			  GL_NEAREST);
}

void drawTo(const Target &target)
{
	GLint previousProgram = 0, previousVao = 0, previousTexture = 0, previousActive = 0;
	GLint viewport[4];
	glGetIntegerv(GL_CURRENT_PROGRAM, &previousProgram);
	glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &previousVao);
	glGetIntegerv(GL_ACTIVE_TEXTURE, &previousActive);
	glActiveTexture(GL_TEXTURE0);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture);
	glGetIntegerv(GL_VIEWPORT, viewport);
	const GLboolean blend = glIsEnabled(GL_BLEND);

	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target.fbo);
	glViewport(0, 0, GLsizei(width), GLsizei(height));
	glDisable(GL_BLEND);
	glUseProgram(program);
	glBindVertexArray(vao);
	glBindTexture(GL_TEXTURE_2D, name(staging));
	glUniform1i(samplerLocation, 0);
	glDrawArrays(GL_TRIANGLES, 0, 3);

	if (blend)
		glEnable(GL_BLEND);
	glBindTexture(GL_TEXTURE_2D, GLuint(previousTexture));
	glActiveTexture(GLenum(previousActive));
	glBindVertexArray(GLuint(previousVao));
	glUseProgram(GLuint(previousProgram));
	glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
}

void copyTo(const Target &target)
{
	GLint previousActive = 0, previousTexture = 0;
	glGetIntegerv(GL_ACTIVE_TEXTURE, &previousActive);
	glActiveTexture(GL_TEXTURE0);
	glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &previousTexture);
	glBindFramebuffer(GL_READ_FRAMEBUFFER, stagingFbo);
	glBindTexture(GL_TEXTURE_RECTANGLE, name(target.texture));
	glCopyTexSubImage2D(GL_TEXTURE_RECTANGLE, 0, 0, 0, 0, 0, GLsizei(width), GLsizei(height));
	glBindTexture(GL_TEXTURE_RECTANGLE, GLuint(previousTexture));
	glActiveTexture(GLenum(previousActive));
}

template<typename Fn> uint64_t timed(Fn &&fn)
{
	const uint64_t start = os_gettime_ns();
	fn();
	return os_gettime_ns() - start;
}

void rendered(void *)
{
	gs_texture_t *mainTexture = obs_get_main_texture();
	if (gs_get_render_target() != mainTexture)
		return;
	if (!ready)
		setup();

	GLint read = 0, draw = 0;
	glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);

	const int slot = frame++ % kRing;

	gs_texture_t *previousTarget = gs_get_render_target();
	const enum gs_color_space previousSpace = gs_get_color_space();
	const uint64_t e = timed([&] {
		gs_viewport_push();
		gs_projection_push();
		gs_set_render_target_with_color_space(staging, nullptr, GS_CS_SRGB);
		gs_set_viewport(0, 0, int(width), int(height));
		gs_ortho(0.0f, float(gs_texture_get_width(mainTexture)), 0.0f,
			 float(gs_texture_get_height(mainTexture)), -100.0f, 100.0f);
		obs_render_main_texture_src_color_only();
		gs_set_render_target_with_color_space(previousTarget, nullptr, previousSpace);
		gs_projection_pop();
		gs_viewport_pop();
	});
	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);

	/* Orden rotatorio para no favorecer a ninguna variante. */
	uint64_t a = 0, b = 0, c = 0, d = 0;
	auto runA = [&] { a = timed([&] { blitTo(plain[slot]); }); };
	auto runB = [&] { b = timed([&] { blitTo(surfaceBlit[slot]); }); };
	auto runC = [&] { c = timed([&] { drawTo(surfaceDraw[slot]); }); };
	auto runD = [&] { d = timed([&] { copyTo(surfaceCopy[slot]); }); };
	switch (frame % 4) {
	case 0: runA(); runB(); runC(); runD(); break;
	case 1: runB(); runC(); runD(); runA(); break;
	case 2: runC(); runD(); runA(); runB(); break;
	default: runD(); runA(); runB(); runC(); break;
	}

	glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(read));
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(draw));

	if (collecting) {
		samplesA.push_back(a);
		samplesB.push_back(b);
		samplesC.push_back(c);
		samplesD.push_back(d);
		samplesE.push_back(e);
	}
}

void print(const char *label, std::vector<uint64_t> values)
{
	std::sort(values.begin(), values.end());
	auto at = [&](double q) { return double(values[size_t(q * double(values.size() - 1))]) / 1000.0; };
	printf("%-44s p50=%7.1f µs  p90=%7.1f µs  p99=%7.1f µs  máx=%7.1f µs\n", label, at(0.5), at(0.9), at(0.99),
	       double(values.back()) / 1000.0);
}

} // namespace

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc >= 3) {
			width = uint32_t(atoi(argv[1]));
			height = uint32_t(atoi(argv[2]));
		}

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
		if (obs_reset_video(&ovi) != OBS_VIDEO_SUCCESS)
			return 2;

		obs_add_main_rendered_callback(rendered, nullptr);
		os_sleep_ms(1000);
		collecting = true;
		os_sleep_ms(8000);
		collecting = false;
		obs_remove_main_rendered_callback(rendered, nullptr);

		printf("copia %ux%u, %zu fotogramas\n", width, height, samplesA.size());
		print("A) blit a textura GL normal", samplesA);
		print("B) blit a IOSurface", samplesB);
		print("C) shader propio sobre IOSurface", samplesC);
		print("D) glCopyTexSubImage2D a IOSurface", samplesD);
		print("E) dibujo libobs a textura intermedia", samplesE);

		obs_shutdown();
		return 0;
	}
}
