#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <vector>

enum class WallpaperTextureChannels : std::uint8_t {
    r = 1,
    rg = 2,
    rgba = 4,
};

struct WallpaperTexture {
    std::uint32_t textureWidth = 0;
    std::uint32_t textureHeight = 0;
    std::uint32_t visibleWidth = 0;
    std::uint32_t visibleHeight = 0;
    WallpaperTextureChannels channels = WallpaperTextureChannels::rgba;
    std::vector<std::uint8_t> pixels;
};

struct WallpaperSceneAssets {
    WallpaperTexture base;
    std::array<WallpaperTexture, 4> shakeMasks;
    std::array<WallpaperTexture, 6> foliageMasks;
    WallpaperTexture noise;
    WallpaperTexture particleHalo;
    WallpaperTexture fireflyHalo;
};

WallpaperSceneAssets loadWallpaperSceneAssets(const std::filesystem::path& scenePackage,
                                              const std::filesystem::path& engineAssetsRoot);
