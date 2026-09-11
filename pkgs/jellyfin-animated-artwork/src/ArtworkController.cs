using System.Security.Claims;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Net.Http.Headers;

namespace Jellyfin.Plugin.AnimatedArtwork;

internal static class ArtworkItems
{
    // Jellyfin 12 uses this same user-aware lookup for its own image and lyrics endpoints.
    internal static MusicAlbum? Resolve(ILibraryManager library, ClaimsPrincipal user, Guid itemId)
    {
        var userId = Guid.TryParse(user.FindFirstValue("Jellyfin-UserId"), out var parsed) ? parsed : Guid.Empty;
        var item = library.GetItemById<BaseItem>(itemId, userId);
        return item switch { MusicAlbum album => album, Audio audio => audio.AlbumEntity, _ => null };
    }

    internal static PhysicalFileResult FileResult(LocatedAsset file, HttpResponse response, bool publiclyCacheable)
    {
        response.Headers.CacheControl = publiclyCacheable ? "public, max-age=3600" : "private, max-age=3600";
        response.Headers.XContentTypeOptions = "nosniff";
        return new PhysicalFileResult(file.Path, file.ContentType)
        {
            EnableRangeProcessing = true,
            EntityTag = new EntityTagHeaderValue('"' + file.Asset.Sha256 + '"'),
            LastModified = new DateTimeOffset(System.IO.File.GetLastWriteTimeUtc(file.Path))
        };
    }
}

public sealed record AssetResponse(string Url, string ContentType, string Sha256, long Bytes, int Width, int Height, double Duration);
public sealed record ArtworkResponse(int ApiVersion, Guid ItemId, Guid AlbumId, AssetResponse Square, AssetResponse? Tall, AssetResponse? Gif);

[ApiController]
[Authorize]
[Route("AnimatedArtwork")]
public sealed class ArtworkController(ILibraryManager library, ArtworkCatalog catalog) : ControllerBase
{
    [HttpGet]
    public ActionResult GetCapabilities() => Ok(new { ApiVersion = 1, Formats = new[] { "video/mp4", "image/gif" } });

    [HttpGet("Items/{itemId:guid}")]
    [ProducesResponseType(typeof(ArtworkResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ArtworkResponse>> GetArtwork(Guid itemId)
    {
        var album = ArtworkItems.Resolve(library, User, itemId);
        var square = await Describe(album?.Path, itemId, "square").ConfigureAwait(false);
        if (album is null || square is null)
        {
            return NotFound();
        }

        Response.Headers.CacheControl = "no-store";
        return new ArtworkResponse(1, itemId, album.Id, square,
            await Describe(album.Path, itemId, "tall").ConfigureAwait(false),
            await Describe(album.Path, itemId, "gif").ConfigureAwait(false));
    }

    [HttpGet("Items/{itemId:guid}/{variant}")]
    [HttpHead("Items/{itemId:guid}/{variant}")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status206PartialContent)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> GetFile(Guid itemId, string variant)
    {
        var album = ArtworkItems.Resolve(library, User, itemId);
        var file = await catalog.LocateAsync(album?.Path, variant, HttpContext.RequestAborted).ConfigureAwait(false);
        return file is null ? NotFound() : ArtworkItems.FileResult(file, Response, publiclyCacheable: false);
    }

    private async Task<AssetResponse?> Describe(string? albumPath, Guid itemId, string variant)
    {
        var file = await catalog.LocateAsync(albumPath, variant, HttpContext.RequestAborted).ConfigureAwait(false);
        return file is null ? null : new AssetResponse(
            $"{Request.PathBase}/AnimatedArtwork/Items/{itemId:D}/{variant}?tag={file.Asset.Sha256}",
            file.ContentType, file.Asset.Sha256, file.Asset.Bytes, file.Asset.Width, file.Asset.Height, file.Asset.Duration);
    }
}
