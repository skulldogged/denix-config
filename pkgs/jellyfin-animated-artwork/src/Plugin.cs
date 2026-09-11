using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Controller;
using MediaBrowser.Controller.Plugins;
using MediaBrowser.Model.Plugins;
using MediaBrowser.Model.Serialization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.DependencyInjection;

namespace Jellyfin.Plugin.AnimatedArtwork;

public sealed class PluginConfiguration : BasePluginConfiguration
{
    public bool EnableAnimatedImages { get; set; } = true;
}

public sealed class Plugin : BasePlugin<PluginConfiguration>, IHasWebPages
{
    public Plugin(IApplicationPaths paths, IXmlSerializer serializer) : base(paths, serializer)
    {
        Instance = this;
    }

    public static Plugin? Instance { get; private set; }
    public override string Name => "Animated Album Artwork";
    public override string Description => "Animated album covers for Jellyfin Web and an MP4 artwork API for music clients.";
    public override Guid Id => new("b5329c03-6d1e-4d41-9fd4-6c5ed58d2446");

    public IEnumerable<PluginPageInfo> GetPages() =>
    [
        new()
        {
            Name = "animatedAlbumArtwork",
            EmbeddedResourcePath = "Jellyfin.Plugin.AnimatedArtwork.Configuration.configPage.html"
        }
    ];
}

public sealed class ServiceRegistrator : IPluginServiceRegistrator
{
    public void RegisterServices(IServiceCollection services, IServerApplicationHost applicationHost)
    {
        services.AddSingleton<Func<PluginConfiguration>>(_ => () => Plugin.Instance?.Configuration ?? new());
        services.AddSingleton<IArtworkMetadataReader, JellyfinArtworkMetadataReader>();
        services.AddSingleton<ArtworkCatalog>();
        services.AddScoped<AnimatedImageFilter>();
        services.Configure<MvcOptions>(options => options.Filters.AddService<AnimatedImageFilter>());
    }
}
