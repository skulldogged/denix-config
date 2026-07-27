{
  description = "Modular configuration of NixOS, Home Manager, and Nix-Darwin with Denix";

  nixConfig = {
    extra-substituters = [
      "https://hyprland.cachix.org/"
      "https://nix-community.cachix.org/"
      "https://pupbrained.cachix.org/"
    ];
    extra-trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "pupbrained.cachix.org-1:C64g/tdHk/o5bl9AZYW1a7XFRXhxa4XaufpIOxMsgxU="
    ];
  };

  inputs = {
    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.home-manager.follows = "home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-colors.url = "github:Misterio77/nix-colors";

    nautilus-my-computer = {
      url = "github:yannmasoch/nautilus-my-computer?dir=packaging/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    nixvim.url = "github:skulldogged/nixvim-new";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    snappy-switcher = {
      url = "github:skulldogged/snappy-switcher/feature/window-previews";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    twemoji-src = {
      url = "github:jdecked/twemoji";
      flake = false;
    };

    bang-bang = {
      url = "github:oh-my-fish/plugin-bang-bang";
      flake = false;
    };

    caelestia-shell = {
      url = "github:dim-ghub/caelestia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex-cli-nix = {
      url = "github:sadjow/codex-cli-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex-desktop-linux = {
      url = "github:ilysenko/codex-desktop-linux";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    t3code-flake = {
      url = "github:omarcresp/t3code-flake";
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

    difftastic-src = {
      url = "github:skulldogged/difftastic";
      flake = false;
    };

    draconisplusplus = {
      url = "github:skulldogged/draconisplusplus-monorepo";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    draconisplusplus-plugins = {
      url = "github:skulldogged/draconisplusplus-plugins";
      inputs.draconisplusplus.follows = "draconisplusplus";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.utils.follows = "draconisplusplus/utils";
    };

    draconisplusplus-plugin-lab = {
      url = "github:skulldogged/draconisplusplus-plugin-lab";
      inputs.draconisplusplus.follows = "draconisplusplus";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.utils.follows = "draconisplusplus/utils";
    };

    fish-git-abbr = {
      url = "github:pupbrained/fish-git-abbr/patch-1";
      flake = false;
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland = {
      url = "github:hyprwm/Hyprland";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    gloview = {
      url = "github:fedsfarm/gloview";
      inputs.hyprland.follows = "hyprland";
    };

    hyprglass = {
      url = "github:hyprnux/hyprglass";
      flake = false;
    };

    jellyfin-src = {
      url = "github:skulldogged/jellyfin";
      flake = false;
    };

    jellyfin-web-src = {
      url = "github:jellyfin/jellyfin-web";
      flake = false;
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    license = {
      url = "github:oh-my-fish/plugin-license";
      flake = false;
    };

    linux-wallpaperengine-src = {
      url = "git+https://github.com/Almamu/linux-wallpaperengine?submodules=1";
      flake = false;
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    replay-fish = {
      url = "github:jorgebucaran/replay.fish";
      flake = false;
    };

    vicinae = {
      url = "github:vicinaehq/vicinae";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {denix, ...} @ inputs: let
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    forAllSystems = inputs.nixpkgs.lib.genAttrs systems;

    treefmtEval = forAllSystems (
      system:
        inputs.treefmt-nix.lib.evalModule (import inputs.nixpkgs {inherit system;}) {
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
    nixosConfigurations =
      inputs.nixpkgs.lib.getAttrs ["navis" "polaris"]
      (mkConfigurations "nixos");

    darwinConfigurations =
      inputs.nixpkgs.lib.getAttrs ["canis"]
      (mkConfigurations "darwin");

    formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

    checks = forAllSystems (system: {
      formatting = treefmtEval.${system}.config.build.check inputs.self;
    });

    devShells = forAllSystems (
      system: let
        pkgs = import inputs.nixpkgs {inherit system;};

        facterScript = pkgs.writeScriptBin "facter" ''
          sudo nix run \
            --option experimental-features "nix-command flakes" \
            --option extra-substituters https://numtide.cachix.org \
            --option extra-trusted-public-keys numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE= \
            github:numtide/nixos-facter -- -o hosts/$(hostname)/facter.json
        '';
      in {
        default = pkgs.mkShellNoCC {
          packages = with pkgs;
            [
              alejandra
              git
              lua-language-server
              nh
              statix

              (writeScriptBin "build" ''
                ${
                  if stdenv.isLinux
                  then ''[ -f "hosts/$(hostname)/facter.json" ] || facter''
                  else ""
                }
                nix fmt
                nh ${
                  if stdenv.isDarwin
                  then "darwin"
                  else "os"
                } switch
              '')
              (writeScriptBin "up" "nix flake update")
            ]
            ++ lib.optionals stdenv.isLinux [facterScript];
        };
      }
    );
  };
}
