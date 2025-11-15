{
  description = "Modular configuration of NixOS, Home Manager, and Nix-Darwin with Denix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    denix = {
      url = "github:yunfachi/denix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.nix-darwin.follows = "nix-darwin";
    };

    # Additional inputs from old config
    agenix.url = "github:ryantm/agenix";
    catppuccin.url = "github:catppuccin/nix";
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    draconisplusplus.url = "github:pupbrained/draconisplusplus";
    impermanence.url = "github:nix-community/impermanence";
    nix-colors.url = "github:Misterio77/nix-colors";
    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
    nixvim.url = "github:pupbrained/nixvim-new";
    treefmt-nix.url = "github:numtide/treefmt-nix";

    hyprland = {
      url = "github:hyprwm/Hyprland";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    quickshell = {
      url = "github:quickshell-mirror/quickshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    vicinae = {
      url = "github:vicinaehq/vicinae";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {denix, ...} @ inputs: let
    mkConfigurations = moduleSystem:
      denix.lib.configurations {
        inherit moduleSystem;
        homeManagerUser = "marshall";

        paths = [
          ./hosts
          ./modules
          ./rices
        ];

        extensions = with denix.lib.extensions; [
          args
          (base.withConfig {
            args.enable = true;
          })
        ];

        specialArgs = {
          inherit inputs;
        };
      };
  in {
    nixosConfigurations = mkConfigurations "nixos";
    homeConfigurations = mkConfigurations "home";
    darwinConfigurations = mkConfigurations "darwin";

    formatter = inputs.nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"] (
      system: let
        pkgs = import inputs.nixpkgs {inherit system;};
      in
        inputs.treefmt-nix.lib.mkWrapper pkgs {
          projectRootFile = "flake.nix";

          programs = {
            alejandra.enable = true;
            deadnix.enable = true;
            jsonfmt.enable = true;
            stylua.enable = true;
            taplo.enable = true;
          };
        }
    );

    devShells = inputs.nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"] (
      system: let
        pkgs = import inputs.nixpkgs {inherit system;};
      in {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            alejandra
            git
            lua-language-server
            nvfetcher
            statix

            (writeScriptBin "build" ''
              ${
                if stdenv.isLinux
                then ''
                  sudo nix run \
                    --option experimental-features "nix-command flakes" \
                    --option extra-substituters https://numtide.cachix.org \
                    --option extra-trusted-public-keys numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE= \
                    github:numtide/nixos-facter -- -o hosts/$(hostname)/facter.json
                ''
                else ""
              }
              nix fmt
              nh ${
                if stdenv.isDarwin
                then "darwin"
                else "os"
              } switch
            '')
            (writeScriptBin "up" "nix flake update && nvfetcher")
          ];
        };
      }
    );
  };
}
