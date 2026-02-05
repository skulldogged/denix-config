{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs,
  pnpm,
  fetchPnpmDeps,
  makeWrapper,
}:
stdenv.mkDerivation rec {
  pname = "lobster";
  version = "2026.1.21";

  src = fetchFromGitHub {
    owner = "openclaw";
    repo = "lobster";
    rev = "main";
    hash = "sha256-zrVn7fpEuExiznAH5j3QqfpGx9a7S640IDSd+nycx3A=";
  };

  nativeBuildInputs = [nodejs pnpm.configHook makeWrapper];

  pnpmDeps = fetchPnpmDeps {
    inherit src pname version;
    fetcherVersion = 1;
    hash = "sha256-CZaSzcDxhazW6ZLHuH73+I4TxCA+4Va5GyMLty0k2nY=";
  };

  buildPhase = ''
    pnpm build
  '';

  installPhase = ''
    mkdir -p $out/lib/lobster
    cp -r . $out/lib/lobster/

    mkdir -p $out/bin
    makeWrapper ${nodejs}/bin/node $out/bin/lobster \
      --add-flags "$out/lib/lobster/bin/lobster.js" \
      --prefix PATH : ${lib.makeBinPath [nodejs]}
  '';

  meta = with lib; {
    description = "Clawdbot-native workflow shell for typed pipelines and approval gates";
    homepage = "https://github.com/openclaw/lobster";
    license = licenses.mit;
    mainProgram = "lobster";
  };
}
