{
  lib,
  buildDotnetModule,
  dotnetCorePackages,
}:
buildDotnetModule {
  pname = "jellyfin-animated-artwork";
  version = "0.1.0";
  src = ./src;
  projectFile = "Jellyfin.Plugin.AnimatedArtwork.csproj";
  nugetDeps = ./deps.json;
  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnet-runtime = dotnetCorePackages.aspnetcore_10_0;
  executables = [];
  useAppHost = false;
  dontPublish = true;
  installPhase = ''
    runHook preInstall
    install -Dm444 bin/Release/net10.0/*/Jellyfin.Plugin.AnimatedArtwork.dll \
      "$out/Jellyfin.Plugin.AnimatedArtwork.dll"
    runHook postInstall
  '';
  meta = {
    description = "Discover animated album artwork beside music files and serve GIF/MP4 artwork through Jellyfin";
    platforms = lib.platforms.linux;
  };
}
