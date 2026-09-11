using MediaBrowser.Controller.Library;
using MediaBrowser.Model.Entities;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Filters;

namespace Jellyfin.Plugin.AnimatedArtwork;

/// <summary>Supplies prepared GIFs through existing image URLs without replacing library files or metadata.</summary>
public sealed class AnimatedImageFilter(
    ILibraryManager library,
    ArtworkCatalog catalog,
    Func<PluginConfiguration> configuration) : IAsyncActionFilter
{
    public async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        if (configuration().EnableAnimatedImages
            && context.ActionDescriptor is ControllerActionDescriptor descriptor
            && descriptor.ControllerTypeInfo.FullName == "Jellyfin.Api.Controllers.ImageController"
            && descriptor.ActionName is "GetItemImage" or "GetItemImageByIndex" or "GetItemImage2"
            && context.ActionArguments.TryGetValue("itemId", out var value) && value is Guid itemId
            && context.ActionArguments.TryGetValue("imageType", out var imageType) && imageType is ImageType.Primary
            && (!context.ActionArguments.TryGetValue("imageIndex", out var imageIndex) || imageIndex is null or 0)
            && !string.Equals(context.HttpContext.Request.Query["animated"], "false", StringComparison.OrdinalIgnoreCase))
        {
            var album = ArtworkItems.Resolve(library, context.HttpContext.User, itemId);
            var gif = await catalog.LocateAsync(album?.Path, "gif", context.HttpContext.RequestAborted).ConfigureAwait(false);
            if (gif is not null)
            {
                // Standard Jellyfin images may be requested anonymously; retain the host's existing access checks.
                context.Result = ArtworkItems.FileResult(gif, context.HttpContext.Response, publiclyCacheable: true);
                return;
            }
        }

        await next().ConfigureAwait(false);
    }
}
