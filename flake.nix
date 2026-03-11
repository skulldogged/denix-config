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
      inputs = {
        home-manager.follows = "home-manager";
        nix-darwin.follows = "nix-darwin";
        nixpkgs.follows = "nixpkgs";
      };
    };

    sops-nix.url = "github:Mic92/sops-nix";
    catppuccin.url = "github:catppuccin/nix";
    impermanence.url = "github:nix-community/impermanence";
    nix-colors.url = "github:Misterio77/nix-colors";
    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
    nixvim.url = "github:skulldogged/nixvim-new";
    opencode.url = "github:anomalyco/opencode/dev";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    vscode-server.url = "github:nix-community/nixos-vscode-server";

    draconisplusplus = {
      url = "github:skulldogged/draconisplusplus-monorepo";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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

    caelestia-shell = {
      url = "github:caelestia-dots/shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    vicinae = {
      url = "github:vicinaehq/vicinae";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    draconisplusplus-plugins = {
      url = "github:skulldogged/draconisplusplus-plugins";
      flake = false;
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    spacebot = {
      url = "github:skulldogged/spacebot-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    aurelia = {
      url = "git+ssh://git@github.com/skulldogged/aurelia";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    linux-wallpaperengine-src = {
      url = "git+https://github.com/Almamu/linux-wallpaperengine?submodules=1";
      flake = false;
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
            nh
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
