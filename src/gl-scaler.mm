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

#include <plugin-support.h>
#include <util/base.h>

#include <OpenGL/gl3.h>

namespace nbp {

namespace {

/* Triángulo que cubre todo el viewport, sin búferes de vértices. */
const char *const kVertexShader = R"(#version 330 core
void main()
{
	vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

/* Las texturas de libobs guardan la fila superior de la imagen en y = 0, y
 * las IOSurface también, así que no hay que invertir el eje vertical. */
const char *const kFragmentShader = R"(#version 330 core
uniform sampler2D image;
uniform vec2 invOutputSize;
uniform vec2 tapOffset;
out vec4 color;
void main()
{
	vec2 uv = gl_FragCoord.xy * invOutputSize;
	vec3 rgb;
	if (tapOffset.x > 0.0) {
		rgb = 0.25 * (texture(image, uv - tapOffset).rgb +
			      texture(image, uv + tapOffset).rgb +
			      texture(image, uv + vec2(tapOffset.x, -tapOffset.y)).rgb +
			      texture(image, uv + vec2(-tapOffset.x, tapOffset.y)).rgb);
	} else {
		rgb = texture(image, uv).rgb;
	}
	color = vec4(rgb, 1.0);
}
)";

GLuint compileShader(GLenum type, const char *source)
{
	GLuint shader = glCreateShader(type);
	glShaderSource(shader, 1, &source, nullptr);
	glCompileShader(shader);

	GLint ok = GL_FALSE;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024] = {};
		glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
		obs_log(LOG_ERROR, "error al compilar el shader: %s", log);
		glDeleteShader(shader);
		return 0;
	}
	return shader;
}

/* Estado GL que modifica draw(); se restaura al salir del ámbito. */
class StateGuard {
public:
	StateGuard()
	{
		glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebuffer_);
		glGetIntegerv(GL_CURRENT_PROGRAM, &program_);
		glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vertexArray_);
		glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture_);
		glActiveTexture(GL_TEXTURE0);
		glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture_);
		glGetIntegerv(GL_SAMPLER_BINDING, &sampler_);
		glGetIntegerv(GL_VIEWPORT, viewport_);
		glGetBooleanv(GL_COLOR_WRITEMASK, colorMask_);
		blend_ = glIsEnabled(GL_BLEND);
		srgb_ = glIsEnabled(GL_FRAMEBUFFER_SRGB);
		scissor_ = glIsEnabled(GL_SCISSOR_TEST);
		cull_ = glIsEnabled(GL_CULL_FACE);
		depth_ = glIsEnabled(GL_DEPTH_TEST);
		stencil_ = glIsEnabled(GL_STENCIL_TEST);
	}

	~StateGuard()
	{
		set(GL_STENCIL_TEST, stencil_);
		set(GL_DEPTH_TEST, depth_);
		set(GL_CULL_FACE, cull_);
		set(GL_SCISSOR_TEST, scissor_);
		set(GL_FRAMEBUFFER_SRGB, srgb_);
		set(GL_BLEND, blend_);
		glColorMask(colorMask_[0], colorMask_[1], colorMask_[2], colorMask_[3]);
		glViewport(viewport_[0], viewport_[1], viewport_[2], viewport_[3]);
		glBindSampler(0, GLuint(sampler_));
		glBindTexture(GL_TEXTURE_2D, GLuint(texture_));
		glActiveTexture(GLenum(activeTexture_));
		glBindVertexArray(GLuint(vertexArray_));
		glUseProgram(GLuint(program_));
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(drawFramebuffer_));
	}

private:
	static void set(GLenum capability, GLboolean enabled)
	{
		if (enabled)
			glEnable(capability);
		else
			glDisable(capability);
	}

	GLint drawFramebuffer_ = 0, program_ = 0, vertexArray_ = 0, activeTexture_ = 0, texture_ = 0, sampler_ = 0;
	GLint viewport_[4] = {};
	GLboolean colorMask_[4] = {};
	GLboolean blend_ = GL_FALSE, srgb_ = GL_FALSE, scissor_ = GL_FALSE, cull_ = GL_FALSE, depth_ = GL_FALSE,
		  stencil_ = GL_FALSE;
};

} // namespace

bool GlScaler::ensure()
{
	if (program_)
		return true;
	if (failed_)
		return false;

	GLint previousProgram = 0;
	glGetIntegerv(GL_CURRENT_PROGRAM, &previousProgram);

	GLuint vertex = compileShader(GL_VERTEX_SHADER, kVertexShader);
	GLuint fragment = compileShader(GL_FRAGMENT_SHADER, kFragmentShader);
	if (vertex && fragment) {
		program_ = glCreateProgram();
		glAttachShader(program_, vertex);
		glAttachShader(program_, fragment);
		glBindFragDataLocation(program_, 0, "color");
		glLinkProgram(program_);

		GLint linked = GL_FALSE;
		glGetProgramiv(program_, GL_LINK_STATUS, &linked);
		if (!linked) {
			char log[1024] = {};
			glGetProgramInfoLog(program_, sizeof(log), nullptr, log);
			obs_log(LOG_ERROR, "error al enlazar el shader: %s", log);
			glDeleteProgram(program_);
			program_ = 0;
		}
	}
	if (vertex)
		glDeleteShader(vertex);
	if (fragment)
		glDeleteShader(fragment);

	if (!program_) {
		failed_ = true;
		return false;
	}

	invOutputSizeLocation_ = glGetUniformLocation(program_, "invOutputSize");
	tapOffsetLocation_ = glGetUniformLocation(program_, "tapOffset");
	glUseProgram(program_);
	glUniform1i(glGetUniformLocation(program_, "image"), 0);
	glUseProgram(GLuint(previousProgram));

	glGenVertexArrays(1, &vao_);

	glGenSamplers(1, &sampler_);
	glSamplerParameteri(sampler_, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glSamplerParameteri(sampler_, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glSamplerParameteri(sampler_, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glSamplerParameteri(sampler_, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

	return true;
}

void GlScaler::destroy()
{
	if (sampler_)
		glDeleteSamplers(1, &sampler_);
	if (vao_)
		glDeleteVertexArrays(1, &vao_);
	if (program_)
		glDeleteProgram(program_);
	sampler_ = 0;
	vao_ = 0;
	program_ = 0;
	failed_ = false;
}

void GlScaler::draw(unsigned int sourceTexture, uint32_t sourceWidth, uint32_t sourceHeight, unsigned int framebuffer,
		    uint32_t width, uint32_t height)
{
	if (!program_ || !sourceTexture || !width || !height)
		return;

	StateGuard guard;

	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
	glViewport(0, 0, GLsizei(width), GLsizei(height));
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	glDisable(GL_BLEND);
	glDisable(GL_SCISSOR_TEST);
	glDisable(GL_CULL_FACE);
	glDisable(GL_DEPTH_TEST);
	glDisable(GL_STENCIL_TEST);
	/* Lectura sRGB -> lineal (filtrado correcto) y escritura lineal -> sRGB. */
	glEnable(GL_FRAMEBUFFER_SRGB);

	glUseProgram(program_);
	glBindVertexArray(vao_);
	glBindTexture(GL_TEXTURE_2D, sourceTexture);
	glBindSampler(0, sampler_);

	const float invWidth = 1.0f / float(width);
	const float invHeight = 1.0f / float(height);
	glUniform2f(invOutputSizeLocation_, invWidth, invHeight);

	const bool downscaleHalfOrMore = width * 2 <= sourceWidth || height * 2 <= sourceHeight;
	if (downscaleHalfOrMore)
		glUniform2f(tapOffsetLocation_, 0.25f * invWidth, 0.25f * invHeight);
	else
		glUniform2f(tapOffsetLocation_, 0.0f, 0.0f);

	glDrawArrays(GL_TRIANGLES, 0, 3);
}

} // namespace nbp
