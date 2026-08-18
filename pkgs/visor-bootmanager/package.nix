{
  lib,
  stdenv,
  fetchFromGitHub,
  gnu-efi,
  gnumake,
  maple-mono,
  python3,
}: let
  pythonWithPillow = python3.withPackages (pythonPackages: [pythonPackages.pillow]);
in
  stdenv.mkDerivation {
    pname = "visor-bootmanager";
    version = "1.4";

    src = fetchFromGitHub {
      owner = "IO-ZetZor";
      repo = "Visor-BootManager";
      rev = "c0e559c725873efa8826a1ec9ee7c1385144794a";
      hash = "sha256-v0TVH0oM5D8y5L68Txgh16KV/H0SPPh2rKK4D5XghN0=";
    };

    nativeBuildInputs = [
      gnumake
      pythonWithPillow
    ];

    postPatch = ''
      substituteInPlace Makefile \
        --replace-fail 'font_jetbrains.c' 'font_maple.c'
      substituteInPlace src/include/font.h \
        --replace-fail 'jetbrains_font' 'maple_font'
      substituteInPlace src/gui.c \
        --replace-fail 'jetbrains_font' 'maple_font' \
        --replace-fail "int is_jb = (name[0] == 'j' || name[0] == 'J');" "int is_maple = (name[0] == 'm' || name[0] == 'M');" \
        --replace-fail 'if (!is_jb)' 'if (!is_maple)' \
        --replace-fail "only the built-in 'jetbrains' font is available" "only the built-in 'maple' font is available"
      python tools/bake_font.py \
        ${maple-mono.NF}/share/fonts/truetype/MapleMono-NF-Regular.ttf \
        128 \
        maple \
        src/font_maple.c
    '';

    makeFlags = [
      "ARCH=x86_64"
      "GNU_EFI_INC=${gnu-efi}/include/efi"
      "CRT0=${gnu-efi}/lib/crt0-efi-x86_64.o"
      "GNU_EFI_LIB=${gnu-efi}/lib/"
    ];

    installPhase = ''
      runHook preInstall

      install -Dm0644 visor_x64.efi "$out/lib/visor/visor_x64.efi"
      install -Dm0644 boot.conf.example "$out/share/visor/boot.conf.example"
      install -Dm0644 docs/boot.conf.schema.json "$out/share/visor/boot.conf.schema.json"
      cp -r assets/icons "$out/share/visor/icons"
      cp -r assets/backgrounds "$out/share/visor/backgrounds"
      install -Dm0644 assets/logo.png "$out/share/visor/logo.png"

      runHook postInstall
    '';

    meta = {
      description = "Minimal graphical UEFI boot manager";
      homepage = "https://github.com/IO-ZetZor/Visor-BootManager";
      license = lib.licenses.bsd2;
      platforms = ["x86_64-linux"];
    };
  }
