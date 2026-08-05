#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <fcntl.h>
#include <gbm.h>
#if defined(__GLIBC__)
#include <malloc.h>
#endif
#include <poll.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wkeyword-macro"
#endif
#define namespace namespace_
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#undef namespace
#if defined(__clang__)
#pragma clang diagnostic pop
#endif
#include "particle_system.hpp"
#include "wallpaper_asset.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

std::atomic_bool keepRunning = true;

void handleSignal(int) { keepRunning = false; }

[[noreturn]] void fail(const std::string& message) { throw std::runtime_error(message); }

template <typename T> T requireProc(const char* name) {
    auto* proc = eglGetProcAddress(name);
    if (proc == nullptr) {
        fail(std::string("Missing EGL/GL procedure: ") + name);
    }
    return reinterpret_cast<T>(proc);
}

struct WaylandState {
    wl_display* display = nullptr;
    wl_registry* registry = nullptr;
    wl_compositor* compositor = nullptr;
    wl_shm* shm = nullptr;
    zwlr_layer_shell_v1* layerShell = nullptr;
    wl_surface* surface = nullptr;
    zwlr_layer_surface_v1* layerSurface = nullptr;
    wl_callback* frameCallback = nullptr;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    bool configured = false;
    bool frameReady = true;
    bool closed = false;

    ~WaylandState() {
        if (frameCallback != nullptr) {
            wl_callback_destroy(frameCallback);
        }
        if (layerSurface != nullptr) {
            zwlr_layer_surface_v1_destroy(layerSurface);
        }
        if (surface != nullptr) {
            wl_surface_destroy(surface);
        }
        if (layerShell != nullptr) {
            zwlr_layer_shell_v1_destroy(layerShell);
        }
        if (shm != nullptr) {
            wl_shm_destroy(shm);
        }
        if (compositor != nullptr) {
            wl_compositor_destroy(compositor);
        }
        if (registry != nullptr) {
            wl_registry_destroy(registry);
        }
        if (display != nullptr) {
            wl_display_disconnect(display);
        }
    }
};

void registryGlobal(void* data, wl_registry* registry, std::uint32_t name, const char* interface,
                    std::uint32_t version) {
    auto& state = *static_cast<WaylandState*>(data);

    if (std::strcmp(interface, wl_compositor_interface.name) == 0) {
        state.compositor = static_cast<wl_compositor*>(
            wl_registry_bind(registry, name, &wl_compositor_interface, std::min(version, 6U)));
    } else if (std::strcmp(interface, wl_shm_interface.name) == 0) {
        state.shm = static_cast<wl_shm*>(
            wl_registry_bind(registry, name, &wl_shm_interface, std::min(version, 1U)));
    } else if (std::strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
        state.layerShell = static_cast<zwlr_layer_shell_v1*>(wl_registry_bind(
            registry, name, &zwlr_layer_shell_v1_interface, std::min(version, 5U)));
    }
}

void registryGlobalRemove(void*, wl_registry*, std::uint32_t) {}

constexpr wl_registry_listener registryListener = {
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

void layerConfigure(void* data, zwlr_layer_surface_v1* surface, std::uint32_t serial,
                    std::uint32_t width, std::uint32_t height) {
    auto& state = *static_cast<WaylandState*>(data);
    zwlr_layer_surface_v1_ack_configure(surface, serial);

    if (width == 0 || height == 0) {
        fail("Compositor configured a zero-sized layer surface");
    }

    if (state.configured && (state.width != width || state.height != height)) {
        fail("Output resize requires restarting the wallpaper renderer");
    }

    state.width = width;
    state.height = height;
    state.configured = true;
}

void layerClosed(void* data, zwlr_layer_surface_v1*) {
    static_cast<WaylandState*>(data)->closed = true;
}

constexpr zwlr_layer_surface_v1_listener layerSurfaceListener = {
    .configure = layerConfigure,
    .closed = layerClosed,
};

void frameDone(void* data, wl_callback* callback, std::uint32_t) {
    auto& state = *static_cast<WaylandState*>(data);
    wl_callback_destroy(callback);
    state.frameCallback = nullptr;
    state.frameReady = true;
}

constexpr wl_callback_listener frameListener = {
    .done = frameDone,
};

struct GlState {
    int drmFd = -1;
    gbm_device* gbm = nullptr;
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    GLuint program = 0;
    GLuint sceneTexture = 0;
    std::array<GLuint, 4> shakeMaskTextures{};
    std::array<GLuint, 6> foliageMaskTextures{};
    GLuint noiseTexture = 0;
    GLuint particleHaloTexture = 0;
    GLuint fireflyHaloTexture = 0;
    GLuint particleProgram = 0;
    GLuint particleVertexArray = 0;
    GLuint particleVertexBuffer = 0;
    GLint timeUniform = -1;
    GLint sceneTextureUniform = -1;
    GLint sceneUvScaleUniform = -1;
    GLint useSceneTextureUniform = -1;
    GLint effectsEnabledUniform = -1;
    GLint shakeOffsetsUniform = -1;
    GLint foliageHorizontalSinesUniform = -1;
    GLint foliageHorizontalCosinesUniform = -1;
    GLint foliageVerticalSinesUniform = -1;
    GLint foliageVerticalCosinesUniform = -1;
    bool hasSceneTexture = false;
    bool effectsEnabled = false;
    bool particlesEnabled = false;
    RanniParticleSystem particleSystem;
    ParticleFrame particleFrame;
    PFNEGLCREATEIMAGEKHRPROC createImage = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC destroyImage = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC imageTargetTexture = nullptr;

    ~GlState() {
        if (sceneTexture != 0) {
            glDeleteTextures(1, &sceneTexture);
        }
        glDeleteTextures(static_cast<GLsizei>(shakeMaskTextures.size()), shakeMaskTextures.data());
        glDeleteTextures(static_cast<GLsizei>(foliageMaskTextures.size()),
                         foliageMaskTextures.data());
        if (noiseTexture != 0) {
            glDeleteTextures(1, &noiseTexture);
        }
        if (particleHaloTexture != 0) {
            glDeleteTextures(1, &particleHaloTexture);
        }
        if (fireflyHaloTexture != 0) {
            glDeleteTextures(1, &fireflyHaloTexture);
        }
        if (particleVertexBuffer != 0) {
            glDeleteBuffers(1, &particleVertexBuffer);
        }
        if (particleVertexArray != 0) {
            glDeleteVertexArrays(1, &particleVertexArray);
        }
        if (particleProgram != 0) {
            glDeleteProgram(particleProgram);
        }
        if (program != 0) {
            glDeleteProgram(program);
        }
        if (display != EGL_NO_DISPLAY) {
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (context != EGL_NO_CONTEXT) {
                eglDestroyContext(display, context);
            }
            eglTerminate(display);
        }
        if (gbm != nullptr) {
            gbm_device_destroy(gbm);
        }
        if (drmFd >= 0) {
            close(drmFd);
        }
    }
};

GLuint compileShader(GLenum type, std::string_view source) {
    const auto shader = glCreateShader(type);
    const char* data = source.data();
    const auto length = static_cast<GLint>(source.size());
    glShaderSource(shader, 1, &data, &length);
    glCompileShader(shader);

    GLint status = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status != GL_TRUE) {
        GLint logLength = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &logLength);
        std::string log(static_cast<std::size_t>(std::max(logLength, 1)), '\0');
        glGetShaderInfoLog(shader, logLength, nullptr, log.data());
        glDeleteShader(shader);
        fail("Shader compilation failed: " + log);
    }
    return shader;
}

GLuint createProgram() {
    constexpr std::string_view vertexSource = R"glsl(#version 300 es
precision highp float;
out vec2 uv;
void main() {
    vec2 position = vec2(
        gl_VertexID == 1 ? 3.0 : -1.0,
        gl_VertexID == 2 ? 3.0 : -1.0
    );
    uv = position * 0.5 + 0.5;
    gl_Position = vec4(position, 0.0, 1.0);
}

)glsl";

    constexpr std::string_view fragmentSource = R"glsl(#version 300 es
precision highp float;
in vec2 uv;
uniform float elapsedSeconds;
uniform sampler2D sceneTexture;
uniform vec2 sceneUvScale;
uniform bool useSceneTexture;
uniform bool effectsEnabled;
uniform vec2 shakeOffsets;
uniform vec4 foliageHorizontalSines[3];
uniform vec4 foliageHorizontalCosines[3];
uniform vec4 foliageVerticalSines[3];
uniform vec4 foliageVerticalCosines[3];
uniform sampler2D shakeMask0;
uniform sampler2D shakeMask1;
uniform sampler2D shakeMask2;
uniform sampler2D shakeMask3;
uniform sampler2D foliageMask0;
uniform sampler2D foliageMask1;
uniform sampler2D foliageMask2;
uniform sampler2D foliageMask3;
uniform sampler2D foliageMask4;
uniform sampler2D foliageMask5;
uniform sampler2D noiseTexture;
out vec4 color;

vec2 shakeDisplacement(vec2 flowColors, float offset) {
    vec2 flow = (flowColors - vec2(0.498)) * 2.0;
    return offset * flow;
}

vec2 foliageDisplacement(float mask, vec2 coordinate, int animationIndex, float strength) {
    const float ratio = 0.3;
    const float phaseAmount = 0.5;
    const float noiseScale = 0.05;
    float aspect = (4096.0 / 2304.0) * ratio;
    float noise = texture(noiseTexture, coordinate * noiseScale).g;
    float phase = (noise * 6.28318530718 + coordinate.x * 10.0 + coordinate.y * 5.0) * phaseAmount;

    float phaseSine = sin(phase);
    float phaseCosine = cos(phase);
    vec4 horizontal = phaseSine * foliageHorizontalCosines[animationIndex] +
                      phaseCosine * foliageHorizontalSines[animationIndex];
    vec4 vertical = phaseSine * foliageVerticalCosines[animationIndex] +
                    phaseCosine * foliageVerticalSines[animationIndex];
    float amplitude = strength * strength * 0.005 * mask;
    return vec2(dot(horizontal, vec4(amplitude)) / aspect,
                dot(vertical, vec4(amplitude)) * aspect);
}

void main() {
    if (useSceneTexture) {
        vec2 sceneUv = uv * sceneUvScale;
        if (effectsEnabled) {
            // The source scene applies four shake passes followed by six foliage passes.
            // Traverse them in reverse to collapse the pass chain into one texture lookup.
            sceneUv += foliageDisplacement(texture(foliageMask5, sceneUv).r, sceneUv, 0, 0.35);
            sceneUv += foliageDisplacement(texture(foliageMask4, sceneUv).r, sceneUv, 1, 0.4);
            sceneUv += foliageDisplacement(texture(foliageMask3, sceneUv).r, sceneUv, 0, 0.4);
            sceneUv += foliageDisplacement(texture(foliageMask2, sceneUv).r, sceneUv, 0, 0.4);
            sceneUv += foliageDisplacement(texture(foliageMask1, sceneUv).r, sceneUv, 2, 0.4);
            sceneUv += foliageDisplacement(texture(foliageMask0, sceneUv).r, sceneUv, 0, 0.5);
            sceneUv += shakeDisplacement(texture(shakeMask3, sceneUv).rg, shakeOffsets.y);
            sceneUv += shakeDisplacement(texture(shakeMask2, sceneUv).rg, shakeOffsets.y);
            sceneUv += shakeDisplacement(texture(shakeMask1, sceneUv).rg, shakeOffsets.x);
            sceneUv += shakeDisplacement(texture(shakeMask0, sceneUv).rg, shakeOffsets.x);
        }
        color = texture(sceneTexture, sceneUv);
        return;
    }

    vec2 centered = uv - 0.5;
    float radius = length(centered);
    float angle = atan(centered.y, centered.x);
    float wave = 0.5 + 0.5 * sin(angle * 6.0 - elapsedSeconds * 1.7 + radius * 18.0);
    vec3 dusk = vec3(0.035, 0.045, 0.075);
    vec3 blue = vec3(0.08, 0.28, 0.52);
    vec3 gold = vec3(0.85, 0.55, 0.16);
    vec3 base = mix(dusk, blue, smoothstep(0.72, 0.05, radius));
    base += gold * wave * smoothstep(0.52, 0.08, radius) * 0.38;
    color = vec4(base, 1.0);
}
)glsl";

    const auto vertex = compileShader(GL_VERTEX_SHADER, vertexSource);
    const auto fragment = compileShader(GL_FRAGMENT_SHADER, fragmentSource);
    const auto program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);

    GLint status = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status != GL_TRUE) {
        GLint logLength = 0;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &logLength);
        std::string log(static_cast<std::size_t>(std::max(logLength, 1)), '\0');
        glGetProgramInfoLog(program, logLength, nullptr, log.data());
        glDeleteProgram(program);
        fail("Program linking failed: " + log);
    }
    return program;
}

GLuint createParticleProgram() {
    constexpr std::string_view vertexSource = R"glsl(#version 300 es
precision highp float;
layout(location = 0) in vec3 particlePositionAndSize;
layout(location = 1) in vec4 particleColor;
uniform vec2 sceneSize;
uniform vec2 outputSize;
out vec4 tint;

void main() {
    vec2 normalized = particlePositionAndSize.xy / sceneSize;
    // Wallpaper Engine's 2D particle space is bottom-origin, unlike the image UVs.
    normalized.y = 1.0 - normalized.y;
    gl_Position = vec4(normalized * 2.0 - 1.0, 0.0, 1.0);
    float outputScale = min(outputSize.x / sceneSize.x, outputSize.y / sceneSize.y);
    gl_PointSize = max(1.0, particlePositionAndSize.z * outputScale);
    tint = particleColor;
}
)glsl";

    constexpr std::string_view fragmentSource = R"glsl(#version 300 es
precision highp float;
in vec4 tint;
uniform sampler2D spriteTexture;
out vec4 color;

void main() {
    vec4 sprite = texture(spriteTexture, gl_PointCoord);
    float opacity = tint.a * sprite.a;
    color = vec4(tint.rgb * sprite.rgb * opacity, opacity);
}
)glsl";

    const auto vertex = compileShader(GL_VERTEX_SHADER, vertexSource);
    const auto fragment = compileShader(GL_FRAGMENT_SHADER, fragmentSource);
    const auto program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);

    GLint status = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status != GL_TRUE) {
        GLint logLength = 0;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &logLength);
        std::string log(static_cast<std::size_t>(std::max(logLength, 1)), '\0');
        glGetProgramInfoLog(program, logLength, nullptr, log.data());
        glDeleteProgram(program);
        fail("Particle program linking failed: " + log);
    }
    return program;
}

std::unique_ptr<GlState> createGlState(const std::string& renderNode) {
    auto state = std::make_unique<GlState>();
    state->drmFd = open(renderNode.c_str(), O_RDWR | O_CLOEXEC);
    if (state->drmFd < 0) {
        fail("Cannot open render node " + renderNode + ": " + std::strerror(errno));
    }

    state->gbm = gbm_create_device(state->drmFd);
    if (state->gbm == nullptr) {
        fail("gbm_create_device failed for " + renderNode);
    }

    const auto getPlatformDisplay =
        requireProc<PFNEGLGETPLATFORMDISPLAYEXTPROC>("eglGetPlatformDisplayEXT");
    state->display = getPlatformDisplay(EGL_PLATFORM_GBM_KHR, state->gbm, nullptr);
    if (state->display == EGL_NO_DISPLAY ||
        eglInitialize(state->display, nullptr, nullptr) != EGL_TRUE) {
        fail("Cannot initialize EGL on " + renderNode);
    }

    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE) {
        fail("eglBindAPI(EGL_OPENGL_ES_API) failed");
    }

    const std::array<EGLint, 3> contextAttributes = {
        EGL_CONTEXT_CLIENT_VERSION,
        3,
        EGL_NONE,
    };
    state->context =
        eglCreateContext(state->display, nullptr, EGL_NO_CONTEXT, contextAttributes.data());
    if (state->context == EGL_NO_CONTEXT) {
        fail("eglCreateContext failed");
    }
    if (eglMakeCurrent(state->display, EGL_NO_SURFACE, EGL_NO_SURFACE, state->context) !=
        EGL_TRUE) {
        fail("Surfaceless eglMakeCurrent failed");
    }

    state->createImage = requireProc<PFNEGLCREATEIMAGEKHRPROC>("eglCreateImageKHR");
    state->destroyImage = requireProc<PFNEGLDESTROYIMAGEKHRPROC>("eglDestroyImageKHR");
    state->imageTargetTexture =
        requireProc<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>("glEGLImageTargetTexture2DOES");

    state->program = createProgram();
    state->particleProgram = createParticleProgram();
    state->timeUniform = glGetUniformLocation(state->program, "elapsedSeconds");
    state->sceneTextureUniform = glGetUniformLocation(state->program, "sceneTexture");
    state->sceneUvScaleUniform = glGetUniformLocation(state->program, "sceneUvScale");
    state->useSceneTextureUniform = glGetUniformLocation(state->program, "useSceneTexture");
    state->effectsEnabledUniform = glGetUniformLocation(state->program, "effectsEnabled");
    state->shakeOffsetsUniform = glGetUniformLocation(state->program, "shakeOffsets");
    state->foliageHorizontalSinesUniform =
        glGetUniformLocation(state->program, "foliageHorizontalSines[0]");
    state->foliageHorizontalCosinesUniform =
        glGetUniformLocation(state->program, "foliageHorizontalCosines[0]");
    state->foliageVerticalSinesUniform =
        glGetUniformLocation(state->program, "foliageVerticalSines[0]");
    state->foliageVerticalCosinesUniform =
        glGetUniformLocation(state->program, "foliageVerticalCosines[0]");

    std::cout << "EGL vendor: " << eglQueryString(state->display, EGL_VENDOR) << '\n';
    std::cout << "GL vendor: " << glGetString(GL_VENDOR) << '\n';
    std::cout << "GL renderer: " << glGetString(GL_RENDERER) << '\n';
    std::cout << "GL version: " << glGetString(GL_VERSION) << '\n';
    return state;
}

GLuint uploadTexture(const WallpaperTexture& texture, GLuint unit, bool repeat) {
    GLint internalFormat = GL_RGBA8;
    GLenum uploadFormat = GL_RGBA;
    if (texture.channels == WallpaperTextureChannels::r) {
        internalFormat = GL_R8;
        uploadFormat = GL_RED;
    } else if (texture.channels == WallpaperTextureChannels::rg) {
        internalFormat = GL_RG8;
        uploadFormat = GL_RG;
    }

    GLuint handle = 0;
    glGenTextures(1, &handle);
    glActiveTexture(GL_TEXTURE0 + unit);
    glBindTexture(GL_TEXTURE_2D, handle);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, repeat ? GL_REPEAT : GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, repeat ? GL_REPEAT : GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, internalFormat, static_cast<GLsizei>(texture.textureWidth),
                 static_cast<GLsizei>(texture.textureHeight), 0, uploadFormat, GL_UNSIGNED_BYTE,
                 texture.pixels.data());
    if (const auto error = glGetError(); error != GL_NO_ERROR) {
        glDeleteTextures(1, &handle);
        fail("Uploading a wallpaper texture failed with GL error " + std::to_string(error));
    }
    return handle;
}

void uploadSceneAssets(GlState& gl, const WallpaperSceneAssets& assets, bool enableEffects) {
    GLint textureUnitCount = 0;
    glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &textureUnitCount);
    constexpr GLint requiredTextureUnits = 12;
    if (textureUnitCount < requiredTextureUnits) {
        fail("The Intel GLES driver exposes too few fragment texture units");
    }

    gl.sceneTexture = uploadTexture(assets.base, 0, false);
    for (std::size_t index = 0; index < gl.shakeMaskTextures.size(); ++index) {
        gl.shakeMaskTextures[index] =
            uploadTexture(assets.shakeMasks[index], static_cast<GLuint>(1U + index), false);
    }
    for (std::size_t index = 0; index < gl.foliageMaskTextures.size(); ++index) {
        gl.foliageMaskTextures[index] =
            uploadTexture(assets.foliageMasks[index], static_cast<GLuint>(5U + index), false);
    }
    gl.noiseTexture = uploadTexture(assets.noise, 11, true);
    gl.particleHaloTexture = uploadTexture(assets.particleHalo, 0, false);
    gl.fireflyHaloTexture = uploadTexture(assets.fireflyHalo, 0, false);

    glGenVertexArrays(1, &gl.particleVertexArray);
    glBindVertexArray(gl.particleVertexArray);
    glGenBuffers(1, &gl.particleVertexBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, gl.particleVertexBuffer);
    constexpr std::size_t maximumParticleVertices = 150;
    glBufferData(GL_ARRAY_BUFFER,
                 static_cast<GLsizeiptr>(maximumParticleVertices * sizeof(ParticleVertex)), nullptr,
                 GL_STREAM_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, static_cast<GLsizei>(sizeof(ParticleVertex)),
                          reinterpret_cast<const void*>(offsetof(ParticleVertex, x)));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, static_cast<GLsizei>(sizeof(ParticleVertex)),
                          reinterpret_cast<const void*>(offsetof(ParticleVertex, red)));
    glBindVertexArray(0);

    glUseProgram(gl.program);
    glUniform1i(gl.sceneTextureUniform, 0);
    for (std::size_t index = 0; index < gl.shakeMaskTextures.size(); ++index) {
        const auto name = "shakeMask" + std::to_string(index);
        glUniform1i(glGetUniformLocation(gl.program, name.c_str()), static_cast<GLint>(1U + index));
    }
    for (std::size_t index = 0; index < gl.foliageMaskTextures.size(); ++index) {
        const auto name = "foliageMask" + std::to_string(index);
        glUniform1i(glGetUniformLocation(gl.program, name.c_str()), static_cast<GLint>(5U + index));
    }
    glUniform1i(glGetUniformLocation(gl.program, "noiseTexture"), 11);
    glUniform2f(gl.sceneUvScaleUniform,
                static_cast<float>(assets.base.visibleWidth) /
                    static_cast<float>(assets.base.textureWidth),
                static_cast<float>(assets.base.visibleHeight) /
                    static_cast<float>(assets.base.textureHeight));
    gl.hasSceneTexture = true;
    gl.effectsEnabled = enableEffects;
    glActiveTexture(GL_TEXTURE0);

    std::cout << "Loaded wallpaper base texture: " << assets.base.visibleWidth << 'x'
              << assets.base.visibleHeight << " with "
              << (enableEffects ? "10 fused deformation masks" : "effects disabled") << '\n';
}

void drawParticleVertices(GLuint texture, GLint first, GLsizei count) {
    if (count == 0) {
        return;
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture);
    glDrawArrays(GL_POINTS, first, count);
}

void updateAnimationUniforms(GlState& gl, float elapsedSeconds) {
    glUniform1f(gl.timeUniform, elapsedSeconds);
    if (!gl.effectsEnabled) {
        return;
    }

    const float shake1 = 0.996F * std::sin(elapsedSeconds) * 0.1F * 0.1F;
    const float shake15 = 0.996F * std::sin(1.5F * elapsedSeconds) * 0.08F * 0.08F;
    glUniform2f(gl.shakeOffsetsUniform, shake1, shake15);

    constexpr std::array<float, 3> speeds = {5.0F, 3.5F, 5.2F};
    constexpr std::array<float, 4> horizontalRates = {
        1.0F, -0.16161616F, 0.0083333F, -0.00019841F};
    constexpr std::array<float, 4> verticalRates = {
        -0.5F, 0.041666666F, -0.0013888889F, 0.000024801587F};
    std::array<GLfloat, 12> horizontalSines{};
    std::array<GLfloat, 12> horizontalCosines{};
    std::array<GLfloat, 12> verticalSines{};
    std::array<GLfloat, 12> verticalCosines{};

    for (std::size_t animation = 0; animation < speeds.size(); ++animation) {
        for (std::size_t component = 0; component < horizontalRates.size(); ++component) {
            const auto index = animation * horizontalRates.size() + component;
            const float horizontalAngle =
                speeds[animation] * elapsedSeconds * horizontalRates[component];
            const float verticalAngle =
                0.4F + speeds[animation] * elapsedSeconds * verticalRates[component];
            horizontalSines[index] = std::sin(horizontalAngle);
            horizontalCosines[index] = std::cos(horizontalAngle);
            verticalSines[index] = std::sin(verticalAngle);
            verticalCosines[index] = std::cos(verticalAngle);
        }
    }

    glUniform4fv(gl.foliageHorizontalSinesUniform, 3, horizontalSines.data());
    glUniform4fv(gl.foliageHorizontalCosinesUniform, 3, horizontalCosines.data());
    glUniform4fv(gl.foliageVerticalSinesUniform, 3, verticalSines.data());
    glUniform4fv(gl.foliageVerticalCosinesUniform, 3, verticalCosines.data());
}

void drawParticles(GlState& gl, float elapsedSeconds) {
    if (!gl.particlesEnabled) {
        return;
    }
    gl.particleSystem.frame(elapsedSeconds, gl.particleFrame);
    const auto& fireflies = gl.particleFrame.fireflies;
    const auto& halos = gl.particleFrame.halos;
    const auto fireflyBytes = fireflies.size() * sizeof(ParticleVertex);
    const auto haloBytes = halos.size() * sizeof(ParticleVertex);

    glUseProgram(gl.particleProgram);
    glBindVertexArray(gl.particleVertexArray);
    glBindBuffer(GL_ARRAY_BUFFER, gl.particleVertexBuffer);
    glBufferSubData(GL_ARRAY_BUFFER, 0, static_cast<GLsizeiptr>(fireflyBytes), fireflies.data());
    glBufferSubData(GL_ARRAY_BUFFER, static_cast<GLintptr>(fireflyBytes),
                    static_cast<GLsizeiptr>(haloBytes), halos.data());
    glEnable(GL_BLEND);
    glBlendEquation(GL_FUNC_ADD);
    glBlendFunc(GL_ONE, GL_ONE);
    drawParticleVertices(gl.fireflyHaloTexture, 0, static_cast<GLsizei>(fireflies.size()));
    drawParticleVertices(gl.particleHaloTexture, static_cast<GLint>(fireflies.size()),
                         static_cast<GLsizei>(halos.size()));
    glDisable(GL_BLEND);
    glBindVertexArray(0);
}

struct RenderTarget {
    GlState* gl = nullptr;
    gbm_bo* bo = nullptr;
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    GLuint texture = 0;
    GLuint framebuffer = 0;

    RenderTarget() = default;
    RenderTarget(const RenderTarget&) = delete;
    RenderTarget& operator=(const RenderTarget&) = delete;
    ~RenderTarget() {
        if (framebuffer != 0) {
            glDeleteFramebuffers(1, &framebuffer);
        }
        if (texture != 0) {
            glDeleteTextures(1, &texture);
        }
        if (image != EGL_NO_IMAGE_KHR && gl != nullptr) {
            gl->destroyImage(gl->display, image);
        }
        if (bo != nullptr) {
            gbm_bo_destroy(bo);
        }
    }
};

std::unique_ptr<RenderTarget> createRenderTarget(GlState& gl, std::uint32_t width,
                                                 std::uint32_t height) {
    auto target = std::make_unique<RenderTarget>();
    target->gl = &gl;
    target->bo = gbm_bo_create(gl.gbm, width, height, GBM_FORMAT_ARGB8888,
                               GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
    if (target->bo == nullptr) {
        fail("Failed to allocate a linear Intel render buffer");
    }

    const int dmaBufFd = gbm_bo_get_fd(target->bo);
    if (dmaBufFd < 0) {
        fail("gbm_bo_get_fd failed");
    }
    const std::array<EGLint, 13> imageAttributes = {
        EGL_WIDTH,
        static_cast<EGLint>(width),
        EGL_HEIGHT,
        static_cast<EGLint>(height),
        EGL_LINUX_DRM_FOURCC_EXT,
        static_cast<EGLint>(GBM_FORMAT_ARGB8888),
        EGL_DMA_BUF_PLANE0_FD_EXT,
        dmaBufFd,
        EGL_DMA_BUF_PLANE0_OFFSET_EXT,
        0,
        EGL_DMA_BUF_PLANE0_PITCH_EXT,
        static_cast<EGLint>(gbm_bo_get_stride(target->bo)),
        EGL_NONE,
    };
    target->image = gl.createImage(gl.display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr,
                                   imageAttributes.data());
    close(dmaBufFd);
    if (target->image == EGL_NO_IMAGE_KHR) {
        fail("EGL failed to import the linear Intel render buffer");
    }

    glGenTextures(1, &target->texture);
    glBindTexture(GL_TEXTURE_2D, target->texture);
    gl.imageTargetTexture(GL_TEXTURE_2D, target->image);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    glGenFramebuffers(1, &target->framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, target->framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target->texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fail("Intel render framebuffer is incomplete");
    }
    return target;
}

struct ShmBuffer {
    wl_buffer* waylandBuffer = nullptr;
    void* data = MAP_FAILED;
    std::size_t size = 0;
    bool busy = false;

    ShmBuffer() = default;
    ShmBuffer(const ShmBuffer&) = delete;
    ShmBuffer& operator=(const ShmBuffer&) = delete;
    ~ShmBuffer() {
        if (waylandBuffer != nullptr) {
            wl_buffer_destroy(waylandBuffer);
        }
        if (data != MAP_FAILED) {
            munmap(data, size);
        }
    }
};

void shmBufferReleased(void* data, wl_buffer*) { static_cast<ShmBuffer*>(data)->busy = false; }

constexpr wl_buffer_listener shmBufferListener = {
    .release = shmBufferReleased,
};

std::unique_ptr<ShmBuffer> createShmBuffer(WaylandState& wayland, std::uint32_t width,
                                           std::uint32_t height) {
    auto buffer = std::make_unique<ShmBuffer>();
    const auto stride = width * 4U;
    buffer->size = static_cast<std::size_t>(stride) * static_cast<std::size_t>(height);

    const int fd = memfd_create("ranni-wallpaper-frame", MFD_CLOEXEC);
    if (fd < 0) {
        fail(std::string("memfd_create failed: ") + std::strerror(errno));
    }
    if (ftruncate(fd, static_cast<off_t>(buffer->size)) < 0) {
        close(fd);
        fail(std::string("ftruncate failed: ") + std::strerror(errno));
    }

    buffer->data = mmap(nullptr, buffer->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (buffer->data == MAP_FAILED) {
        close(fd);
        fail(std::string("mmap failed: ") + std::strerror(errno));
    }

    auto* pool = wl_shm_create_pool(wayland.shm, fd, static_cast<std::int32_t>(buffer->size));
    buffer->waylandBuffer = wl_shm_pool_create_buffer(
        pool, 0, static_cast<std::int32_t>(width), static_cast<std::int32_t>(height),
        static_cast<std::int32_t>(stride), WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);

    if (buffer->waylandBuffer == nullptr) {
        fail("Wayland failed to create a shared-memory buffer");
    }
    wl_buffer_add_listener(buffer->waylandBuffer, &shmBufferListener, buffer.get());
    return buffer;
}

void drawFrame(GlState& gl, WaylandState& wayland, RenderTarget& target, float elapsedSeconds) {
    glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer);
    glViewport(0, 0, static_cast<GLsizei>(wayland.width), static_cast<GLsizei>(wayland.height));
    glUseProgram(gl.program);
    updateAnimationUniforms(gl, elapsedSeconds);
    if (gl.hasSceneTexture) {
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, gl.sceneTexture);
    }
    glDrawArrays(GL_TRIANGLES, 0, 3);
    drawParticles(gl, elapsedSeconds);

    static bool loggedFirstPixel = false;
    if (!loggedFirstPixel) {
        std::array<GLubyte, 4> centerPixel{};
        glReadPixels(static_cast<GLint>(wayland.width / 2U),
                     static_cast<GLint>(wayland.height / 2U), 1, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                     centerPixel.data());
        std::cerr << "First Intel-rendered center pixel: rgba("
                  << static_cast<unsigned>(centerPixel[0]) << ", "
                  << static_cast<unsigned>(centerPixel[1]) << ", "
                  << static_cast<unsigned>(centerPixel[2]) << ", "
                  << static_cast<unsigned>(centerPixel[3]) << ")\n";
        loggedFirstPixel = true;
    }
}

void commitFrame(WaylandState& wayland, wl_buffer* buffer) {
    wl_surface_attach(wayland.surface, buffer, 0, 0);
    wl_surface_damage_buffer(wayland.surface, 0, 0, static_cast<std::int32_t>(wayland.width),
                             static_cast<std::int32_t>(wayland.height));
    wayland.frameCallback = wl_surface_frame(wayland.surface);
    wl_callback_add_listener(wayland.frameCallback, &frameListener, &wayland);
    wayland.frameReady = false;
    wl_surface_commit(wayland.surface);
    wl_display_flush(wayland.display);
}

void renderShmFrame(GlState& gl, WaylandState& wayland, RenderTarget& renderTarget,
                    ShmBuffer& presentationBuffer, float elapsedSeconds) {
    drawFrame(gl, wayland, renderTarget, elapsedSeconds);
    glReadPixels(0, 0, static_cast<GLsizei>(wayland.width), static_cast<GLsizei>(wayland.height),
                 GL_BGRA_EXT, GL_UNSIGNED_BYTE, presentationBuffer.data);
    const auto error = glGetError();
    if (error != GL_NO_ERROR) {
        fail("Full-frame Intel readback failed with GL error " + std::to_string(error));
    }

    presentationBuffer.busy = true;
    commitFrame(wayland, presentationBuffer.waylandBuffer);
}

void dispatchWithTimeout(wl_display* display, int timeoutMilliseconds) {
    while (wl_display_prepare_read(display) != 0) {
        if (wl_display_dispatch_pending(display) < 0) {
            fail("Wayland dispatch failed");
        }
    }

    wl_display_flush(display);
    pollfd descriptor = {
        .fd = wl_display_get_fd(display),
        .events = POLLIN,
        .revents = 0,
    };
    const int result = poll(&descriptor, 1, timeoutMilliseconds);
    if (result > 0 && (descriptor.revents & POLLIN) != 0) {
        if (wl_display_read_events(display) < 0) {
            fail("Wayland event read failed");
        }
    } else {
        wl_display_cancel_read(display);
    }

    if (result < 0 && errno != EINTR) {
        fail(std::string("poll failed: ") + std::strerror(errno));
    }
    if (wl_display_dispatch_pending(display) < 0) {
        fail("Wayland pending-event dispatch failed");
    }
}

std::unique_ptr<WaylandState> createWaylandState(bool overlay) {
    auto state = std::make_unique<WaylandState>();
    state->display = wl_display_connect(nullptr);
    if (state->display == nullptr) {
        fail("Cannot connect to the Wayland compositor");
    }

    state->registry = wl_display_get_registry(state->display);
    wl_registry_add_listener(state->registry, &registryListener, state.get());
    wl_display_roundtrip(state->display);
    wl_display_roundtrip(state->display);

    if (state->compositor == nullptr || state->shm == nullptr || state->layerShell == nullptr) {
        fail("Compositor is missing wl_compositor, wl_shm, or layer-shell support");
    }

    state->surface = wl_compositor_create_surface(state->compositor);
    state->layerSurface = zwlr_layer_shell_v1_get_layer_surface(
        state->layerShell, state->surface, nullptr,
        overlay ? ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY : ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
        "ranni-wallpaper");
    zwlr_layer_surface_v1_add_listener(state->layerSurface, &layerSurfaceListener, state.get());
    zwlr_layer_surface_v1_set_anchor(state->layerSurface, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                                                              ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
                                                              ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                                                              ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
    zwlr_layer_surface_v1_set_exclusive_zone(state->layerSurface, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(
        state->layerSurface, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
    zwlr_layer_surface_v1_set_size(state->layerSurface, 0, 0);
    wl_surface_commit(state->surface);

    while (!state->configured && !state->closed) {
        if (wl_display_dispatch(state->display) < 0) {
            fail("Wayland connection closed before layer configuration");
        }
    }
    return state;
}

int run(const std::string& renderNode, const std::filesystem::path& scenePackage,
        const std::filesystem::path& engineAssetsRoot, bool overlay, bool testPattern,
        bool enableEffects, bool enableParticles) {
    auto wayland = createWaylandState(overlay);
    auto gl = createGlState(renderNode);
    if (!testPattern) {
        uploadSceneAssets(*gl, loadWallpaperSceneAssets(scenePackage, engineAssetsRoot),
                          enableEffects);
#if defined(__GLIBC__)
        malloc_trim(0);
#endif
        gl->particlesEnabled = enableParticles;
    }

    glUseProgram(gl->program);
    glUniform1i(gl->useSceneTextureUniform, gl->hasSceneTexture ? 1 : 0);
    glUniform1i(gl->effectsEnabledUniform, gl->effectsEnabled ? 1 : 0);
    glUseProgram(gl->particleProgram);
    glUniform2f(glGetUniformLocation(gl->particleProgram, "sceneSize"), 4096.0F, 2304.0F);
    glUniform2f(glGetUniformLocation(gl->particleProgram, "outputSize"),
                static_cast<float>(wayland->width), static_cast<float>(wayland->height));
    glUniform1i(glGetUniformLocation(gl->particleProgram, "spriteTexture"), 0);

    std::cout << "Layer size: " << wayland->width << 'x' << wayland->height << '\n';
    auto renderTarget = createRenderTarget(*gl, wayland->width, wayland->height);

    std::vector<std::unique_ptr<ShmBuffer>> shmBuffers;
    shmBuffers.reserve(2);
    for (int index = 0; index < 2; ++index) {
        shmBuffers.emplace_back(createShmBuffer(*wayland, wayland->width, wayland->height));
    }

    std::cout << "Presentation path: CPU-staged wl_shm\n";
    std::cout << "Presenting at 30 FPS. Press Ctrl+C to stop.\n";

    const auto started = std::chrono::steady_clock::now();
    auto nextFrame = started;
    constexpr auto frameInterval = std::chrono::microseconds(33'333);

    while (keepRunning && !wayland->closed) {
        const auto beforeDispatch = std::chrono::steady_clock::now();
        int timeoutMilliseconds = 100;
        if (wayland->frameReady) {
            const auto remaining = nextFrame - beforeDispatch;
            if (remaining <= std::chrono::steady_clock::duration::zero()) {
                timeoutMilliseconds = 0;
            } else {
                timeoutMilliseconds = std::min(
                    static_cast<int>(
                        std::chrono::ceil<std::chrono::milliseconds>(remaining).count()),
                    100);
            }
        }
        dispatchWithTimeout(wayland->display, timeoutMilliseconds);
        const auto now = std::chrono::steady_clock::now();
        if (now < nextFrame || !wayland->frameReady) {
            continue;
        }

        const float elapsed = std::chrono::duration<float>(now - started).count();
        auto available = std::find_if(shmBuffers.begin(), shmBuffers.end(),
                                      [](const auto& buffer) { return !buffer->busy; });
        if (available == shmBuffers.end()) {
            continue;
        }
        renderShmFrame(*gl, *wayland, *renderTarget, **available, elapsed);
        nextFrame = std::max(nextFrame + frameInterval, now);
    }

    glFinish();
    wl_display_roundtrip(wayland->display);
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    signal(SIGINT, handleSignal);
    signal(SIGTERM, handleSignal);

    std::string renderNode = "/dev/dri/renderD129";
    std::filesystem::path scenePackage =
        "/mnt/Shared/SteamLibrary/steamapps/workshop/content/431960/2847826034/scene.pkg";
    std::filesystem::path engineAssetsRoot =
        "/mnt/Shared/SteamLibrary/steamapps/common/wallpaper_engine/assets";
    bool overlay = false;
    bool testPattern = false;
    bool enableEffects = true;
    bool enableParticles = true;
    bool renderNodeSet = false;
    for (int index = 1; index < argc; ++index) {
        const std::string_view option(argv[index]);
        if (option == "--overlay") {
            overlay = true;
        } else if (option == "--test-pattern") {
            testPattern = true;
        } else if (option == "--no-effects") {
            enableEffects = false;
            enableParticles = false;
        } else if (option == "--no-particles") {
            enableParticles = false;
        } else if (option == "--scene-pkg") {
            if (++index >= argc) {
                std::cerr << "--scene-pkg requires a path\n";
                return 2;
            }
            scenePackage = argv[index];
        } else if (option == "--engine-assets") {
            if (++index >= argc) {
                std::cerr << "--engine-assets requires a path\n";
                return 2;
            }
            engineAssetsRoot = argv[index];
        } else if (!option.starts_with("--") && !renderNodeSet) {
            renderNode = option;
            renderNodeSet = true;
        } else {
            std::cerr << "Unknown option: " << option << '\n';
            return 2;
        }
    }
    try {
        return run(renderNode, scenePackage, engineAssetsRoot, overlay, testPattern, enableEffects,
                   enableParticles);
    } catch (const std::exception& error) {
        std::cerr << "ranni-wallpaper: " << error.what() << '\n';
        return 1;
    }
}
