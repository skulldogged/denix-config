{
  inputs,
  pkgs,
  nugetDepsFile ? ./jellyfin-nuget-deps.json,
}: let
  fetchNupkg = pkgs.callPackage (inputs.nixpkgs + "/pkgs/build-support/dotnet/fetch-nupkg") {
    inherit (pkgs.dotnetCorePackages) patchNupkgs nugetPackageHook;
  };

  jellyfin-web = (pkgs.jellyfin-web.override {nodejs_22 = pkgs.nodejs_24;}).overrideAttrs (old: {
    version = "12.0.0";
    src = inputs.jellyfin-web-src;
    npmDeps = let
      packageLock = builtins.fromJSON (builtins.readFile (inputs.jellyfin-web-src + "/package-lock.json"));
      pdfjsPath = "node_modules/pdfjs-dist";
      pdfjs = packageLock.packages.${pdfjsPath} or null;
    in
      pkgs.importNpmLock {
        npmRoot = inputs.jellyfin-web-src;
        packageLock =
          packageLock
          // {
            packages =
              builtins.removeAttrs packageLock.packages ["node_modules/pdfjs-dist/node_modules/canvas"]
              // pkgs.lib.optionalAttrs (pdfjs != null) {
                ${pdfjsPath} =
                  pdfjs
                  // {
                    optionalDependencies = builtins.removeAttrs (pdfjs.optionalDependencies or {}) ["canvas"];
                  };
              };
          };
      };
    nativeBuildInputs =
      builtins.filter
      (input: (input.pname or "") != "npm-config-hook")
      (old.nativeBuildInputs or [])
      ++ [pkgs.importNpmLock.npmConfigHook];
  });
in
  (pkgs.jellyfin.override {
    inherit jellyfin-web;
    dotnetCorePackages =
      pkgs.dotnetCorePackages
      // {
        sdk_9_0 = pkgs.dotnetCorePackages.sdk_10_0;
        aspnetcore_9_0 = pkgs.dotnetCorePackages.aspnetcore_10_0;
      };
  }).overrideAttrs (old: {
    version = "12.0.0";
    src = inputs.jellyfin-src;
    nugetDeps = nugetDepsFile;
    buildInputs =
      (old.buildInputs or [])
      ++ (map fetchNupkg (pkgs.lib.importJSON nugetDepsFile));
  })
