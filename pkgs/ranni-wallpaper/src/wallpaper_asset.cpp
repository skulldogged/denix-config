#include "wallpaper_asset.hpp"

#include <lz4.h>

#define STB_IMAGE_IMPLEMENTATION
#include <stb/stb_image.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstring>
#include <fstream>
#include <limits>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>

namespace {

constexpr std::string_view baseTextureName = "materials/FTl4G03WAAA5jYq.tex";
constexpr std::array<std::string_view, 4> shakeMaskNames = {
    "materials/masks/shake_mask_96f3446c.tex",
    "materials/masks/shake_mask_913936ba.tex",
    "materials/masks/shake_mask_82912559.tex",
    "materials/masks/shake_mask_085ced5d.tex",
};
constexpr std::array<std::string_view, 6> foliageMaskNames = {
    "materials/masks/foliagesway_mask_08ae9924.tex",
    "materials/masks/foliagesway_mask_c6cae753.tex",
    "materials/masks/foliagesway_mask_27cc23af.tex",
    "materials/masks/foliagesway_mask_00f7b5f6.tex",
    "materials/masks/foliagesway_mask_7db9c12c.tex",
    "materials/masks/foliagesway_mask_d4bcbd0d.tex",
};
constexpr auto unknownFreeImageFormat = std::numeric_limits<std::uint32_t>::max();

[[noreturn]] void assetError(const std::string& message) {
    throw std::runtime_error("Wallpaper asset error: " + message);
}

class Cursor {
  public:
    explicit Cursor(std::span<const std::uint8_t> bytes) : bytes_(bytes) {}

    [[nodiscard]] std::size_t offset() const { return offset_; }

    std::uint32_t u32() {
        require(4);
        const auto value = static_cast<std::uint32_t>(bytes_[offset_]) |
                           (static_cast<std::uint32_t>(bytes_[offset_ + 1]) << 8U) |
                           (static_cast<std::uint32_t>(bytes_[offset_ + 2]) << 16U) |
                           (static_cast<std::uint32_t>(bytes_[offset_ + 3]) << 24U);
        offset_ += 4;
        return value;
    }

    std::string sizedString() {
        const auto length = u32();
        const auto data = take(length);
        return {reinterpret_cast<const char*>(data.data()), data.size()};
    }

    std::string magic() {
        const auto data = take(9);
        const auto length = std::find(data.begin(), data.end(), std::uint8_t{0}) - data.begin();
        return {reinterpret_cast<const char*>(data.data()), static_cast<std::size_t>(length)};
    }

    std::span<const std::uint8_t> take(std::size_t size) {
        require(size);
        const auto result = bytes_.subspan(offset_, size);
        offset_ += size;
        return result;
    }

  private:
    void require(std::size_t size) const {
        if (offset_ > bytes_.size() || size > bytes_.size() - offset_) {
            assetError("truncated binary data");
        }
    }

    std::span<const std::uint8_t> bytes_;
    std::size_t offset_ = 0;
};

struct PackageEntry {
    std::string name;
    std::uint32_t offset = 0;
    std::uint32_t length = 0;
};

std::vector<std::uint8_t> readFile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) {
        assetError("cannot open " + path.string());
    }

    const auto end = input.tellg();
    if (end < 0) {
        assetError("cannot determine size of " + path.string());
    }
    const auto size = static_cast<std::size_t>(end);
    std::vector<std::uint8_t> bytes(size);
    input.seekg(0);
    input.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    if (!input) {
        assetError("cannot read complete file " + path.string());
    }
    return bytes;
}

class PackageArchive {
  public:
    explicit PackageArchive(const std::filesystem::path& path) : bytes_(readFile(path)) {
        Cursor cursor(bytes_);
        const auto packageMagic = cursor.sizedString();
        if (!packageMagic.starts_with("PKGV")) {
            assetError("unexpected package magic " + packageMagic);
        }

        const auto entryCount = cursor.u32();
        entries_.reserve(entryCount);
        for (std::uint32_t index = 0; index < entryCount; ++index) {
            entries_.push_back(
                {.name = cursor.sizedString(), .offset = cursor.u32(), .length = cursor.u32()});
        }
        baseOffset_ = cursor.offset();
    }

    [[nodiscard]] std::span<const std::uint8_t> entry(std::string_view wantedName) const {
        const auto found =
            std::find_if(entries_.begin(), entries_.end(), [wantedName](const auto& candidate) {
                return candidate.name == wantedName;
            });
        if (found == entries_.end()) {
            assetError("package does not contain " + std::string(wantedName));
        }

        const auto start = baseOffset_ + static_cast<std::size_t>(found->offset);
        const auto length = static_cast<std::size_t>(found->length);
        if (start > bytes_.size() || length > bytes_.size() - start) {
            assetError("package entry extends beyond package bounds: " + found->name);
        }
        return std::span(bytes_).subspan(start, length);
    }

  private:
    std::vector<std::uint8_t> bytes_;
    std::vector<PackageEntry> entries_;
    std::size_t baseOffset_ = 0;
};

WallpaperTextureChannels channelsForFormat(std::uint32_t format) {
    switch (format) {
    case 0:
        return WallpaperTextureChannels::rgba;
    case 8:
        return WallpaperTextureChannels::rg;
    case 9:
        return WallpaperTextureChannels::r;
    default:
        assetError("unsupported texture pixel format " + std::to_string(format));
    }
}

WallpaperTexture parseTexture(std::span<const std::uint8_t> bytes, std::string_view label) {
    Cursor texture(bytes);
    if (const auto magic = texture.magic(); magic != "TEXV0005") {
        assetError(std::string(label) + " has unsupported texture header " + magic);
    }
    if (const auto magic = texture.magic(); magic != "TEXI0001") {
        assetError(std::string(label) + " has unsupported information header " + magic);
    }

    const auto format = texture.u32();
    std::ignore = texture.u32(); // flags
    WallpaperTexture result = {
        .textureWidth = texture.u32(),
        .textureHeight = texture.u32(),
        .visibleWidth = texture.u32(),
        .visibleHeight = texture.u32(),
        .channels = channelsForFormat(format),
        .pixels = {},
    };
    std::ignore = texture.u32();

    const auto container = texture.magic();
    const auto imageCount = texture.u32();
    if (imageCount == 0) {
        assetError(std::string(label) + " contains no images");
    }

    bool hasCompressionFields = false;
    std::uint32_t freeImageFormat = unknownFreeImageFormat;
    if (container == "TEXB0004") {
        freeImageFormat = texture.u32();
        std::ignore = texture.u32(); // MP4 flag
        hasCompressionFields = true;
    } else if (container == "TEXB0003") {
        freeImageFormat = texture.u32();
        hasCompressionFields = true;
    } else if (container == "TEXB0002") {
        hasCompressionFields = true;
    } else if (container != "TEXB0001") {
        assetError(std::string(label) + " has unsupported container " + container);
    }

    const auto mipmapCount = texture.u32();
    if (mipmapCount == 0) {
        assetError(std::string(label) + " contains no mipmaps");
    }

    const auto mipWidth = texture.u32();
    const auto mipHeight = texture.u32();
    std::uint32_t compression = 0;
    std::uint32_t uncompressedSize = 0;
    if (hasCompressionFields) {
        compression = texture.u32();
        uncompressedSize = texture.u32();
    }
    const auto storedSize = texture.u32();
    if (!hasCompressionFields || compression == 0) {
        uncompressedSize = storedSize;
    }
    if (storedSize > static_cast<std::uint32_t>(std::numeric_limits<int>::max()) ||
        uncompressedSize > static_cast<std::uint32_t>(std::numeric_limits<int>::max())) {
        assetError(std::string(label) + " exceeds supported decoder size");
    }

    const auto stored = texture.take(storedSize);
    std::vector<std::uint8_t> payload(uncompressedSize);
    if (compression == 0) {
        std::memcpy(payload.data(), stored.data(), stored.size());
    } else if (compression == 1) {
        const auto decoded = LZ4_decompress_safe(
            reinterpret_cast<const char*>(stored.data()), reinterpret_cast<char*>(payload.data()),
            static_cast<int>(stored.size()), static_cast<int>(payload.size()));
        if (decoded != static_cast<int>(payload.size())) {
            assetError(std::string(label) + " LZ4 decompression returned an unexpected size");
        }
    } else {
        assetError(std::string(label) + " uses unsupported compression " +
                   std::to_string(compression));
    }

    if (freeImageFormat != unknownFreeImageFormat) {
        int decodedWidth = 0;
        int decodedHeight = 0;
        int sourceChannels = 0;
        auto* decoded = stbi_load_from_memory(payload.data(), static_cast<int>(payload.size()),
                                              &decodedWidth, &decodedHeight, &sourceChannels, 4);
        if (decoded == nullptr) {
            assetError(std::string(label) +
                       " embedded image decode failed: " + stbi_failure_reason());
        }
        if (decodedWidth != static_cast<int>(mipWidth) ||
            decodedHeight != static_cast<int>(mipHeight)) {
            stbi_image_free(decoded);
            assetError(std::string(label) + " decoded dimensions disagree with its header");
        }
        const auto decodedSize =
            static_cast<std::size_t>(decodedWidth) * static_cast<std::size_t>(decodedHeight) * 4U;
        result.pixels.assign(decoded, decoded + decodedSize);
        stbi_image_free(decoded);
        result.textureWidth = mipWidth;
        result.textureHeight = mipHeight;
        result.channels = WallpaperTextureChannels::rgba;
        return result;
    }

    const auto channelCount = static_cast<std::uint64_t>(result.channels);
    const auto expectedSize = static_cast<std::uint64_t>(mipWidth) * mipHeight * channelCount;
    if (expectedSize > std::numeric_limits<std::uint32_t>::max() ||
        payload.size() != expectedSize) {
        assetError(std::string(label) + " has unexpected mipmap dimensions or byte size");
    }
    if (mipWidth != result.textureWidth || mipHeight != result.textureHeight) {
        assetError(std::string(label) + " top mipmap dimensions disagree with its header");
    }
    result.pixels = std::move(payload);
    return result;
}

void requireTextureShape(const WallpaperTexture& texture, std::string_view label,
                         std::uint32_t width, std::uint32_t height,
                         WallpaperTextureChannels channels) {
    if (texture.textureWidth != width || texture.textureHeight != height ||
        texture.visibleWidth != width || texture.visibleHeight != height ||
        texture.channels != channels) {
        assetError(std::string(label) + " does not match this scene's expected texture shape");
    }
}

} // namespace

WallpaperSceneAssets loadWallpaperSceneAssets(const std::filesystem::path& scenePackage,
                                              const std::filesystem::path& engineAssetsRoot) {
    const PackageArchive package(scenePackage);
    WallpaperSceneAssets result = {
        .base = parseTexture(package.entry(baseTextureName), baseTextureName),
        .shakeMasks = {},
        .foliageMasks = {},
        .noise = parseTexture(readFile(engineAssetsRoot / "materials/util/noise.tex"),
                              "materials/util/noise.tex"),
        .particleHalo = parseTexture(readFile(engineAssetsRoot / "materials/particle/halo.tex"),
                                     "materials/particle/halo.tex"),
        .fireflyHalo = parseTexture(readFile(engineAssetsRoot / "materials/particle/halo_3.tex"),
                                    "materials/particle/halo_3.tex"),
    };

    for (std::size_t index = 0; index < shakeMaskNames.size(); ++index) {
        result.shakeMasks[index] =
            parseTexture(package.entry(shakeMaskNames[index]), shakeMaskNames[index]);
    }
    for (std::size_t index = 0; index < foliageMaskNames.size(); ++index) {
        result.foliageMasks[index] =
            parseTexture(package.entry(foliageMaskNames[index]), foliageMaskNames[index]);
    }
    requireTextureShape(result.base, baseTextureName, 4096, 2304, WallpaperTextureChannels::rgba);
    for (std::size_t index = 0; index < shakeMaskNames.size(); ++index) {
        requireTextureShape(result.shakeMasks[index], shakeMaskNames[index], 2048, 1152,
                            WallpaperTextureChannels::rg);
    }
    for (std::size_t index = 0; index < foliageMaskNames.size(); ++index) {
        requireTextureShape(result.foliageMasks[index], foliageMaskNames[index], 2048, 1152,
                            WallpaperTextureChannels::r);
    }
    requireTextureShape(result.noise, "materials/util/noise.tex", 256, 256,
                        WallpaperTextureChannels::rgba);
    if (result.particleHalo.channels != WallpaperTextureChannels::rgba ||
        result.fireflyHalo.channels != WallpaperTextureChannels::rgba) {
        assetError("particle halo textures are not RGBA");
    }
    return result;
}
