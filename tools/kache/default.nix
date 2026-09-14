{
  pkgs,
  homeDir ? "/home/marshall",
  remoteEnabled ? true,
}:
# Dedicated user profile: avoids activating unrelated NixOS/Home Manager changes.
# Credentials must remain outside this derivation and the Nix store.
pkgs.stdenvNoCC.mkDerivation {
  pname = "mars-kache-environment";
  version = "0.20.0";
  src = pkgs.fetchurl {
    url = "https://github.com/kunobi-ninja/kache/releases/download/v0.20.0/kache-x86_64-unknown-linux-musl.tar.gz";
    sha256 = "fe5ce52406e0dcb8c9a49798671a073440cae13a88731b1b712b7c0fa372b85b";
  };
  dontUnpack = true;
  dontStrip = true;
  installPhase = ''
    mkdir -p $out/bin $out/share/kache
    tar -xzf $src -C $out/bin kache
    chmod 755 $out/bin/kache
    cat > $out/share/kache/cargo.toml <<EOF
    [build]
    rustc-wrapper = "${homeDir}/.local/state/nix/profiles/kache/bin/kache"
    EOF
    cat > $out/share/kache/config.toml <<EOF
    [cache]
    local_store = "${homeDir}/.cache/kache"
    local_only = ${
      if remoteEnabled
      then "false"
      else "true"
    }
    local_max_size = "5GiB"
    [cache.remote]
    type = "s3"
    bucket = "kache-cache"
    endpoint = "https://s3.us-east-005.backblazeb2.com"
    region = "us-east-005"
    profile = "kache"
    EOF
  '';
  meta.platforms = ["x86_64-linux"];
}
