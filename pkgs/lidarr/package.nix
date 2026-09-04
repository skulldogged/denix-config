{
  applyPatches,
  buildDotnetModule,
  dotnetCorePackages,
  fetchFromGitHub,
  fetchYarnDeps,
  fixup-yarn-lock,
  lib,
  nodejs,
  prefetch-yarn-deps,
  sqlite,
  stdenvNoCC,
  yarn,
}: let
  version = "3.1.4.5029";
  src = applyPatches {
    src = fetchFromGitHub {
      owner = "Lidarr";
      repo = "Lidarr";
      rev = "570f9a515ae7319d5df698cb4715cf718e7590d2";
      hash = "sha256-e2+r6srhIjr2/7zkwvEuzjQ2YxTKDRUMAJJRg05yOPc=";
    };
    patches = [
      ./allow-search-only-indexers.patch
      ./preserve-linux-punctuation.patch
    ];
    postPatch = ''
      mv src/NuGet.config NuGet.Config
    '';
  };
  rid = dotnetCorePackages.systemToDotnetRid stdenvNoCC.hostPlatform.system;
in
  buildDotnetModule {
    pname = "lidarr";
    inherit version src;

    strictDeps = true;
    nativeBuildInputs = [
      nodejs
      yarn
      prefetch-yarn-deps
      fixup-yarn-lock
    ];

    yarnOfflineCache = fetchYarnDeps {
      yarnLock = "${src}/yarn.lock";
      hash = "sha256-Jq2O7gvB+PKcz6uDBMg7ox6/Bu+pikXH6JGuLfKG5fI=";
    };

    postConfigure = ''
      yarn config --offline set yarn-offline-mirror "$yarnOfflineCache"
      fixup-yarn-lock yarn.lock
      yarn install --offline --frozen-lockfile --ignore-platform --ignore-scripts --no-progress --non-interactive
      patchShebangs --build node_modules
    '';

    postBuild = ''
      yarn --offline run build --env production
    '';

    postInstall = ''
      cp -a -- _output/UI "$out/lib/lidarr/UI"
    '';

    nugetDeps = ./deps.json;
    runtimeDeps = [sqlite];

    dotnet-sdk = dotnetCorePackages.sdk_8_0;
    dotnet-runtime = dotnetCorePackages.aspnetcore_8_0;

    doCheck = true;
    __structuredAttrs = true;
    executables = ["Lidarr"];

    projectFile = [
      "src/NzbDrone.Console/Lidarr.Console.csproj"
      "src/NzbDrone.Mono/Lidarr.Mono.csproj"
    ];

    testProjectFile = ["src/NzbDrone.Core.Test/Lidarr.Core.Test.csproj"];

    preCheck = ''
      cp _output/net8.0/${rid}/Lidarr.Mono.dll _tests/net8.0/${rid}/
    '';

    dotnetFlags = [
      "--property:TargetFramework=net8.0"
      "--property:EnableAnalyzers=false"
      "--property:SentryUploadSymbols=false"
      "--property:Copyright=Copyright 2017-2026 lidarr.audio (GNU General Public v3)"
      "--property:AssemblyVersion=${version}"
      "--property:AssemblyConfiguration=develop"
      "--property:RuntimeIdentifier=${rid}"
    ];

    testFilters = [
      "TestCategory!=ManualTest"
      "TestCategory!=IntegrationTest"
      "TestCategory!=AutomationTest"
      "FullyQualifiedName~NzbDrone.Core.Test.OrganizerTests"
      "FullyQualifiedName!~NzbDrone.Core.Test.UpdateTests.UpdatePackageProviderFixture"
      "FullyQualifiedName!~NzbDrone.Core.Test.ImportListTests.SpotifyMappingFixture"
      "FullyQualifiedName!~NzbDrone.Core.Test.MetadataSource.SkyHook.SkyHookProxyFixture"
      "FullyQualifiedName!~NzbDrone.Core.Test.MetadataSource.SkyHook.SkyHookProxySearchFixture"
      "FullyQualifiedName!~NzbDrone.Core.Test.Http.HttpProxySettingsProviderFixture"
    ];

    meta = {
      description = "Usenet/BitTorrent music downloader with Linux punctuation preservation";
      homepage = "https://lidarr.audio";
      changelog = "https://github.com/Lidarr/Lidarr/releases/tag/v${version}";
      license = lib.licenses.gpl3Only;
      mainProgram = "Lidarr";
      platforms = lib.platforms.linux;
    };
  }
