using System.Security.Cryptography;
using MediaBrowser.Common;
using MediaBrowser.Controller.MediaEncoding;
using MediaBrowser.Model.Dlna;
using MediaBrowser.Model.Dto;
using MediaBrowser.Model.Entities;
using MediaBrowser.Model.MediaInfo;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AnimatedArtwork;

public sealed record ArtworkDimensions(int Width, int Height, double Duration);
public sealed record ArtworkAsset(string Sha256, long Bytes, int Width, int Height, double Duration);
public sealed record LocatedAsset(string Path, ArtworkAsset Asset, string ContentType);

public interface IArtworkMetadataReader
{
    Task<ArtworkDimensions> ReadAsync(string path, CancellationToken cancellationToken);
}

public sealed class JellyfinArtworkMetadataReader(IMediaEncoder encoder) : IArtworkMetadataReader
{
    public async Task<ArtworkDimensions> ReadAsync(string path, CancellationToken cancellationToken)
    {
        var info = await encoder.GetMediaInfo(new MediaInfoRequest
        {
            MediaType = DlnaProfileType.Video,
            MediaSource = new MediaSourceInfo { Path = path, Protocol = MediaProtocol.File },
            ExtractChapters = false
        }, cancellationToken).ConfigureAwait(false);
        var video = info.MediaStreams.FirstOrDefault(stream => stream.Type is MediaStreamType.Video or MediaStreamType.EmbeddedImage);
        if (video?.Width is not > 0 || video.Height is not > 0 || info.RunTimeTicks is not > 0)
        {
            throw new InvalidDataException("Animated cover has no valid video dimensions or duration.");
        }

        return new(video.Width.Value, video.Height.Value, info.RunTimeTicks.Value / (double)TimeSpan.TicksPerSecond);
    }
}

/// <summary>Discovers conventional sidecars directly in the album directory supplied by Jellyfin.</summary>
public sealed class ArtworkCatalog(IArtworkMetadataReader metadata, ILogger<ArtworkCatalog> logger) : IDisposable
{
    private readonly MemoryCache _cache = new(new MemoryCacheOptions { SizeLimit = 256 });
    private readonly SemaphoreSlim _probeGate = new(1, 1);

    public async Task<LocatedAsset?> LocateAsync(string? albumPath, string variant, CancellationToken cancellationToken = default)
    {
        var name = variant switch
        {
            "square" => "animated-cover.mp4",
            "tall" => "animated-cover-tall.mp4",
            "gif" => "animated-cover.gif",
            _ => null
        };
        if (name is null || string.IsNullOrWhiteSpace(albumPath) || !Path.IsPathFullyQualified(albumPath)) return null;
        var fullPath = Path.Combine(albumPath, name);
        try
        {
            var file = new FileInfo(fullPath);
            if (!file.Exists || file.Length is <= 0 or > 67108864 || (file.Attributes & FileAttributes.ReparsePoint) != 0) return null;
            var stamp = (file.Length, file.LastWriteTimeUtc, file.CreationTimeUtc);
            if (_cache.TryGetValue<CachedAsset>(fullPath, out var cached) && cached is not null && cached.Stamp == stamp) return cached.File;

            await _probeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (_cache.TryGetValue<CachedAsset>(fullPath, out cached) && cached is not null && cached.Stamp == stamp) return cached.File;
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(TimeSpan.FromSeconds(15));
                var dimensions = await metadata.ReadAsync(fullPath, timeout.Token).ConfigureAwait(false);
                if (dimensions.Duration is <= 0 or > 90) throw new InvalidDataException("Animated cover must be a loop of at most 90 seconds.");
                await using var stream = File.OpenRead(fullPath);
                var hash = Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, timeout.Token).ConfigureAwait(false));
                file.Refresh();
                if (!file.Exists || (file.Length, file.LastWriteTimeUtc, file.CreationTimeUtc) != stamp) return null;
                var result = new LocatedAsset(fullPath, new(hash, file.Length, dimensions.Width, dimensions.Height, dimensions.Duration), variant == "gif" ? "image/gif" : "video/mp4");
                _cache.Set(fullPath, new CachedAsset(stamp, result), new MemoryCacheEntryOptions { Size = 1, SlidingExpiration = TimeSpan.FromMinutes(10) });
                return result;
            }
            finally { _probeGate.Release(); }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception exception) when (exception is IOException or InvalidDataException or FfmpegException or UnauthorizedAccessException or ArgumentException or OperationCanceledException)
        {
            logger.LogWarning(exception, "Unable to read animated cover {Path}; using the normal cover", fullPath);
            return null;
        }
    }

    public void Dispose() { _cache.Dispose(); _probeGate.Dispose(); }
    private sealed record CachedAsset((long, DateTime, DateTime) Stamp, LocatedAsset File);
}
