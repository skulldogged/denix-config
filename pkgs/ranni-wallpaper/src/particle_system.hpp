#pragma once

#include <vector>

struct ParticleVertex {
    float x = 0.0F;
    float y = 0.0F;
    float size = 0.0F;
    float red = 0.0F;
    float green = 0.0F;
    float blue = 0.0F;
    float alpha = 0.0F;
};

struct ParticleFrame {
    std::vector<ParticleVertex> fireflies;
    std::vector<ParticleVertex> halos;
};

class RanniParticleSystem {
  public:
    void frame(float elapsedSeconds, ParticleFrame& result) const;
};
