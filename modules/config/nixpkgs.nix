{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "nixpkgs";

  nixos.always.nixpkgs = {
    config.allowUnfree = true;

    overlays = [
      (_final: prev: {
        local = {
          cobalt = prev.callPackage ../../pkgs/cobalt/package.nix {};
          jellyfin = prev.callPackage ../../pkgs/jellyfin/package.nix {
            inherit inputs;
            pkgs = prev;
          };
          ranni-wallpaper = prev.callPackage ../../pkgs/ranni-wallpaper/package.nix {};
          slskd = prev.callPackage ../../pkgs/slskd/package.nix {};
        };

        # moonlight-qt 6.1.0 still reads AVCodec.pix_fmts, which FFmpeg 8+
        # removed. Keep it on 7.x until nixpkgs ships a newer Moonlight.
        moonlight-qt = prev.moonlight-qt.override {ffmpeg = prev.ffmpeg_7;};
      })
    ];
  };

  darwin.always.nixpkgs.config.allowUnfree = true;
}
