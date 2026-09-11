# Jellyfin animated artwork

Source snapshot from `aurelia/plugins/jellyfin-animated-artwork/Jellyfin.Plugin.AnimatedArtwork`, targeting the host's Jellyfin 12.0.0 API.

The derivation compiles the plugin with .NET 10 and hash-pinned NuGet packages. It installs only the plugin DLL; Jellyfin supplies its own runtime dependencies. The Polaris Jellyfin service links that DLL into its plugin directory in `preStart`, preserving all other plugins.

Artwork is discovered directly in each music album folder as `animated-cover.mp4`, optional `animated-cover-tall.mp4`, and `animated-cover.gif`. There is no separate artwork directory or index to configure.

When updating, synchronize the source files from Aurelia and regenerate the NuGet dependency hashes when the project references change. The snapshot is kept in this repository so a system rebuild does not depend on another working tree or an absolute home-directory source path.
