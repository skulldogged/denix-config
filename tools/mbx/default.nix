{ pkgs ? import (builtins.getFlake "nixpkgs").outPath {} }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "mars-mbx-environment";
  version = "1.15.0";
  src = pkgs.fetchurl {
    url = "https://github.com/jdx/mr-boxington/releases/download/v1.15.0/mbx-x86_64-unknown-linux-musl.tar.gz";
    sha256 = "bf9fcc7ed39e4923588f6c25a781aa59eb466fec347102a3bb1a0c2acd12ebf8";
  };
  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    mkdir -p $out/bin $out/share/mbx
    install -m755 mbx $out/bin/mbx
    printf '[build]\n' > $out/share/mbx/cargo.toml
    printf '[gc]\nmax_size = "5GiB"\n' > $out/share/mbx/config.toml
    printf 'export PATH="$HOME/.local/share/mbx/bin:$HOME/.local/bin:$PATH"\n' > $out/share/mbx/bashrc
    cat > $out/share/mbx/mbx.fish <<'EOF'
    fish_add_path --move --prepend --path $HOME/.local/share/mbx/bin $HOME/.local/bin
    function cargo --description 'Cargo through mr-boxington'
        $HOME/.local/share/mbx/bin/cargo $argv
    end
    EOF
  '';
}
