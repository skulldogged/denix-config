{
  applyPatches,
  buildDotnetModule,
  dotnetCorePackages,
  fetchFromGitHub,
  lib,
  stdenvNoCC,
}: let
  version = "1.1.3.0";
  minimumLidarrVersion = "3.0.0.4855";
  rid = dotnetCorePackages.systemToDotnetRid stdenvNoCC.hostPlatform.system;

  src = applyPatches {
    src = fetchFromGitHub {
      owner = "allquiet-hub";
      repo = "Lidarr.Plugin.Slskd";
      rev = "ed511d92ab85d36fb3b47a0cdcb8ffb3e4fc8de2";
      fetchSubmodules = true;
      gitConfigFile = builtins.toFile "lidarr-plugin-slskd-gitconfig" ''
        [url "https://github.com/"]
          insteadOf = git@github.com:
      '';
      hash = "sha256-Gdi5tNpJjbU4ME1QrF+ZNnVBUONMltDE6KuYkeOYIkE=";
    };

    patches = [./lossless-codecs.patch];

    postPatch = ''
      mv src/NuGet.config NuGet.Config
      substituteInPlace src/Directory.Build.props \
        --replace-fail '<AssemblyVersion>10.0.0.*</AssemblyVersion>' '<AssemblyVersion>${version}</AssemblyVersion>' \
        --replace-fail '<AssemblyConfiguration>$(Configuration)-dev</AssemblyConfiguration>' '<AssemblyConfiguration>nix</AssemblyConfiguration>'
      substituteInPlace src/Lidarr/src/Directory.Build.props \
        --replace-fail '<AssemblyVersion>10.0.0.*</AssemblyVersion>' '<AssemblyVersion>${minimumLidarrVersion}</AssemblyVersion>' \
        --replace-fail '<AssemblyConfiguration>$(Configuration)-dev</AssemblyConfiguration>' '<AssemblyConfiguration>nix</AssemblyConfiguration>'
    '';
  };
in
  buildDotnetModule {
    pname = "lidarr-plugin-slskd";
    inherit version src;

    __structuredAttrs = true;
    strictDeps = true;
    executables = [];

    projectFile = "src/Lidarr.Plugin.Slskd/Lidarr.Plugin.Slskd.csproj";
    testProjectFile = "src/Lidarr.Plugin.Slskd.LosslessTests/Lidarr.Plugin.Slskd.LosslessTests.csproj";

    # Generated from the exact plugin commit and its pinned Lidarr submodule.
    nugetDeps = ./deps.json;

    dotnet-sdk = dotnetCorePackages.sdk_8_0;
    dotnet-runtime = dotnetCorePackages.aspnetcore_8_0;

    dotnetFlags = [
      "--property:EnableAnalyzers=false"
      "--property:SentryUploadSymbols=false"
      "--property:Copyright=Copyright 2017-2026 lidarr.audio (GNU General Public v3)"
      "--property:TargetFramework=net8.0"
    ];

    doCheck = true;
    checkPhase = ''
      runHook preCheck

      dotnet \
        _plugins/net8.0/Lidarr.Plugin.Slskd.LosslessTests/${rid}/Lidarr.Plugin.Slskd.LosslessTests.dll

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp -a _plugins/net8.0/Lidarr.Plugin.Slskd/${rid}/. "$out/"

      runHook postInstall
    '';

    meta = {
      description = "Soulseek indexer and download client plugin for Lidarr with complete lossless codec detection";
      homepage = "https://github.com/allquiet-hub/Lidarr.Plugin.Slskd";
      changelog = "https://github.com/allquiet-hub/Lidarr.Plugin.Slskd/releases/tag/v${version}";
      license = lib.licenses.gpl3Only;
      platforms = lib.platforms.linux;
    };
  }
