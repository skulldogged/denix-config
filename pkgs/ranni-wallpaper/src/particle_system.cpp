#include "particle_system.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <numbers>

namespace {

struct Vec2 {
    float x = 0.0F;
    float y = 0.0F;
};

struct EmitterTransform {
    Vec2 origin;
    Vec2 scale;
    float angle = 0.0F;
};

constexpr std::array<EmitterTransform, 2> fireflyEmitters = {{
    {{3289.61670F, 375.70706F}, {1.18202F, 1.33997F}, 0.13138F},
    {{508.89832F, 394.80872F}, {1.15352F, 1.37956F}, 0.18604F},
}};

constexpr std::array<EmitterTransform, 2> dustEmitters = {{
    {{921.09558F, 1980.11584F}, {0.46486F, 0.21459F}, -1.57631F},
    {{175.33118F, 1888.72327F}, {0.46486F, 0.21419F}, -1.57631F},
}};

// Wallpaper Engine's generic-particle size is projected smaller than a direct
// scene-pixel diameter on this 2D camera. This measured scale matches the
// installed scene's halo footprint at 2560x1440.
constexpr float fireflySpriteScale = 0.42F;

std::uint32_t mix(std::uint32_t value) {
    value ^= value >> 16U;
    value *= 0x7feb352dU;
    value ^= value >> 15U;
    value *= 0x846ca68bU;
    return value ^ (value >> 16U);
}

float random01(std::uint32_t seed) {
    return static_cast<float>(mix(seed) & 0x00ffffffU) / static_cast<float>(0x01000000U);
}

float randomRange(std::uint32_t seed, float minimum, float maximum) {
    return minimum + (maximum - minimum) * random01(seed);
}

Vec2 transformVector(Vec2 value, const EmitterTransform& transform) {
    value.x *= transform.scale.x;
    value.y *= transform.scale.y;
    const float cosine = std::cos(transform.angle);
    const float sine = std::sin(transform.angle);
    return {
        value.x * cosine - value.y * sine,
        value.x * sine + value.y * cosine,
    };
}

float lifetimeFade(float age, float lifetime, float fadeIn, float fadeOut) {
    const float entering = std::clamp(age / fadeIn, 0.0F, 1.0F);
    const float leaving = std::clamp((lifetime - age) / fadeOut, 0.0F, 1.0F);
    return std::min(entering, leaving);
}

struct Cycle {
    float age = 0.0F;
    float lifetime = 0.0F;
    std::uint32_t seed = 0;
};

Cycle cycleFor(float elapsed, float prewarm, std::uint32_t slotSeed, float minimumLifetime,
               float maximumLifetime) {
    const float nominalLifetime = randomRange(slotSeed + 1U, minimumLifetime, maximumLifetime);
    const float stagger = random01(slotSeed + 2U) * nominalLifetime;
    const float timeline = std::max(0.0F, elapsed + prewarm + stagger);
    const auto generation = static_cast<std::uint32_t>(timeline / nominalLifetime);
    const float age = std::fmod(timeline, nominalLifetime);
    const std::uint32_t generationSeed = mix(slotSeed ^ (generation * 0x9e3779b9U));
    return {
        .age = age,
        .lifetime = nominalLifetime,
        .seed = generationSeed,
    };
}

Vec2 fireflyPosition(const EmitterTransform& emitter, const Cycle& cycle, float age) {
    const float angle = randomRange(cycle.seed + 2U, 0.0F, 2.0F * std::numbers::pi_v<float>);
    const float radius =
        std::sqrt(random01(cycle.seed + 3U)) * randomRange(cycle.seed + 4U, 32.0F, 512.0F);
    const Vec2 initial =
        transformVector({std::cos(angle) * radius, std::sin(angle) * radius * 0.5F}, emitter);
    const float phase = randomRange(cycle.seed + 5U, 0.0F, 2.0F * std::numbers::pi_v<float>);
    const float frequency = randomRange(cycle.seed + 6U, 0.3F, 1.0F);
    const float orbit = randomRange(cycle.seed + 7U, 5.0F, 15.0F);
    const Vec2 drift = {
        std::sin(age * frequency * 2.0F + phase) * orbit +
            std::sin(age * 0.37F + phase * 1.7F) * 8.0F,
        std::cos(age * frequency * 1.7F + phase) * orbit +
            std::sin(age * 0.29F + phase * 0.6F) * 6.0F,
    };
    return {emitter.origin.x + initial.x + drift.x, emitter.origin.y + initial.y + drift.y};
}

void appendFireflies(ParticleFrame& frame, float elapsed) {
    constexpr int particlesPerEmitter = 10;
    constexpr int trailSamples = 2;
    for (std::size_t emitterIndex = 0; emitterIndex < fireflyEmitters.size(); ++emitterIndex) {
        const auto& emitter = fireflyEmitters[emitterIndex];
        for (int slot = 0; slot < particlesPerEmitter; ++slot) {
            const std::uint32_t slotSeed = 0x10000U +
                                           static_cast<std::uint32_t>(emitterIndex) * 0x100U +
                                           static_cast<std::uint32_t>(slot) * 0x10U;
            const Cycle cycle = cycleFor(elapsed, 15.0F, slotSeed, 3.0F, 20.0F);
            const float baseAlpha = 0.75F * lifetimeFade(cycle.age, cycle.lifetime, 0.1F, 0.9F);
            const float flickerFrequency = randomRange(cycle.seed + 8U, 10.0F, 20.0F);
            const float flicker =
                0.7F + 0.3F * (0.5F + 0.5F * std::sin(cycle.age * flickerFrequency));
            const float sizeWave = 1.0F + 0.1F * std::sin(cycle.age * 5.0F);
            const float emitterScale = (emitter.scale.x + emitter.scale.y) * 0.5F;
            const Vec2 position = fireflyPosition(emitter, cycle, cycle.age);
            const float red = randomRange(cycle.seed + 9U, 136.0F, 174.0F) / 255.0F;
            const float green = 1.0F;
            const float blue = randomRange(cycle.seed + 10U, 80.0F, 106.0F) / 255.0F;
            frame.fireflies.push_back({
                .x = position.x,
                .y = position.y,
                .size = randomRange(cycle.seed + 11U, 70.0F, 90.0F) * emitterScale * sizeWave *
                        fireflySpriteScale,
                .red = red,
                .green = green,
                .blue = blue,
                .alpha = baseAlpha * flicker,
            });

            for (int trail = 1; trail <= trailSamples; ++trail) {
                const float delay = static_cast<float>(trail) * 0.075F;
                if (cycle.age <= delay) {
                    continue;
                }
                const Vec2 trailPosition = fireflyPosition(emitter, cycle, cycle.age - delay);
                const float trailScale = 1.0F - static_cast<float>(trail) * 0.24F;
                frame.halos.push_back({
                    .x = trailPosition.x,
                    .y = trailPosition.y,
                    .size = randomRange(cycle.seed + 12U, 20.0F, 50.0F) * emitterScale *
                            trailScale * fireflySpriteScale,
                    .red = red,
                    .green = green,
                    .blue = blue,
                    .alpha = baseAlpha * 0.22F * trailScale,
                });
            }
        }
    }
}

void appendDust(ParticleFrame& frame, float elapsed) {
    // The scene overrides each preset's count to 0.35: 128 * 0.35 rounds to 45.
    constexpr int particlesPerEmitter = 45;
    for (std::size_t emitterIndex = 0; emitterIndex < dustEmitters.size(); ++emitterIndex) {
        const auto& emitter = dustEmitters[emitterIndex];
        for (int slot = 0; slot < particlesPerEmitter; ++slot) {
            const std::uint32_t slotSeed = 0x50000U +
                                           static_cast<std::uint32_t>(emitterIndex) * 0x1000U +
                                           static_cast<std::uint32_t>(slot) * 0x10U;
            const Cycle cycle = cycleFor(elapsed, 1.0F, slotSeed, 3.0F, 10.0F);
            const Vec2 initial = transformVector({randomRange(cycle.seed + 2U, -1024.0F, 1024.0F),
                                                  randomRange(cycle.seed + 3U, -512.0F, 512.0F)},
                                                 emitter);
            const Vec2 velocity = transformVector({randomRange(cycle.seed + 4U, -10.0F, 10.0F),
                                                   randomRange(cycle.seed + 5U, -10.0F, 10.0F)},
                                                  emitter);
            const float phase =
                randomRange(cycle.seed + 6U, 0.0F, 2.0F * std::numbers::pi_v<float>);
            const float oscillationFrequency = randomRange(cycle.seed + 7U, 0.5F, 1.0F);
            const float oscillationScale = randomRange(cycle.seed + 8U, 0.0F, 10.0F);
            const float dragDistance = 1.0F - std::exp(-cycle.age);
            const Vec2 position = {
                emitter.origin.x + initial.x + velocity.x * dragDistance +
                    std::sin(cycle.age * oscillationFrequency + phase) * oscillationScale,
                emitter.origin.y + initial.y + velocity.y * dragDistance +
                    std::cos(cycle.age * oscillationFrequency + phase) * oscillationScale,
            };
            const float pulseFrequency = randomRange(cycle.seed + 9U, 3.0F, 7.0F);
            const float pulse = 0.5F + 0.3F * (0.5F + 0.5F * std::sin(cycle.age * pulseFrequency));
            const float alpha = 0.75F * lifetimeFade(cycle.age, cycle.lifetime, 0.3F, 0.7F) * pulse;
            frame.halos.push_back({
                .x = position.x,
                .y = position.y,
                .size = 5.0F,
                .red = randomRange(cycle.seed + 10U, 251.0F, 255.0F) / 255.0F,
                .green = randomRange(cycle.seed + 11U, 242.0F, 255.0F) / 255.0F,
                .blue = randomRange(cycle.seed + 12U, 176.0F, 180.0F) / 255.0F,
                .alpha = alpha,
            });
        }
    }
}

} // namespace

void RanniParticleSystem::frame(float elapsedSeconds, ParticleFrame& result) const {
    result.fireflies.clear();
    result.halos.clear();
    if (result.fireflies.capacity() < 20) {
        result.fireflies.reserve(20);
    }
    if (result.halos.capacity() < 130) {
        result.halos.reserve(130);
    }
    appendFireflies(result, elapsedSeconds);
    appendDust(result, elapsedSeconds);
}
