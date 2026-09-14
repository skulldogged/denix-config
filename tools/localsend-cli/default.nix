{pkgs ? import <nixpkgs> {}}:
pkgs.stdenv.mkDerivation {
  pname = "localsend-cli";
  version = "1.18.2";
  src = pkgs.fetchurl {
    url = "https://github.com/localsend/localsend/releases/download/v1.18.2/LocalSend-CLI-1.18.2-linux-x86-64.tar.gz";
    sha256 = "f5a986e0b4701b9aafeb9747225a2f3e314e97aba61b3dd7c9d076226f512b08";
  };
  nativeBuildInputs = [pkgs.autoPatchelfHook];
  buildInputs = [pkgs.stdenv.cc.cc.lib];
  sourceRoot = ".";
  dontBuild = true;
  installPhase = "install -Dm755 localsend-cli $out/bin/localsend-cli";
}
