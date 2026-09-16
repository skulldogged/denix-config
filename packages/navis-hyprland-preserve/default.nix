{
  pkgs,
  inputs,
}:
pkgs.lib.makeOverridable (
  {enableXWayland ? true}: let
    inherit (pkgs) lib;
    system = pkgs.stdenv.hostPlatform.system;
    stock = inputs.hyprland.packages.${system}.hyprland;
    aquamarine = inputs.hyprland.inputs.aquamarine.packages.${system}.default.overrideAttrs (old: {
      patches = (old.patches or []) ++ [./aquamarine.patch];
    });
    compositor = (stock.override {inherit aquamarine enableXWayland;}).overrideAttrs (old: {
      pname = "hyprland-navis-migration";
      patches = (old.patches or []) ++ [./hyprland.patch];
      # Match the experimentally verified renderer build. Keep Xwayland/systemd.
      cmakeBuildType = "Release";
      cmakeFlags =
        old.cmakeFlags
        ++ [
          "-DCMAKE_DISABLE_PRECOMPILE_HEADERS=OFF"
          "-DMIGRATION_LAB_FAST_BUILD=ON"
        ];
    });
    eglGenerator = pkgs.writeText "eglGenerator" ''
      #!/usr/bin/env python3
      """Generate EGL 1.5 forwarding functions from the matching upstream header."""
      from pathlib import Path
      import re
      import subprocess
      root = Path(__file__).resolve().parent
      include = Path(subprocess.check_output(['pkg-config', '--variable=includedir', 'egl'], text=True).strip())
      header = (include / 'EGL/egl.h').read_text()
      output = (root / 'egl-loader-prefix.c').read_text()
      declarations = re.findall(r'EGLAPI\s+(.+?)\s*EGLAPIENTRY\s+(egl\w+)\s*\(([^;]*)\);', header)
      assert len(declarations) >= 40, len(declarations)
      for result, name, params in declarations:
          args = ''' if params.strip() == 'void' else ', '.join(re.search(r'(\w+)\s*$', p).group(1) for p in params.split(','))
          track = '''
          if name == 'eglCreateContext':
              track = 'if (lab_result != EGL_NO_CONTEXT) ++live_contexts;'
          elif name == 'eglDestroyContext':
              track = 'if (lab_result && live_contexts) --live_contexts;'
          output += f''''\n{result} EGLAPIENTRY {name}({params}) {{
          pthread_mutex_lock(&lock);
          {result} (*fn)({params}) = resolve("{name}");
          {result} lab_result = fn({args});
          {track}
          pthread_mutex_unlock(&lock);
          return lab_result;
      }}
      ''''
      (root / 'build/egl-loader.c').write_text(output)
      print(f'Generated {len(declarations)} EGL entry points')
    '';
    eglPrefix = pkgs.writeText "eglPrefix" ''
      // Laboratory-only ELF shim. Every EGL context must be explicitly destroyed
      // and EGL users quiesced before unloading. Never installed system-wide.
      #define _GNU_SOURCE
      #include <EGL/egl.h>
      #include <dlfcn.h>
      #include <stdlib.h>
      #include <stdio.h>
      #include <pthread.h>

      static void *module;
      static unsigned live_contexts;
      static pthread_mutex_t lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;

      static void *resolve(const char *name) {
          if (!module) {
              const char *path = getenv("HYPRLAND_LAB_REAL_EGL");
              if (!path || !getenv("HYPRLAND_MIGRATION_LAB")) abort();
              module = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
              if (!module) { fprintf(stderr, "EGL lab loader: %s\n", dlerror()); abort(); }
          }
          void *fn = dlsym(module, name);
          if (!fn) { fprintf(stderr, "EGL lab loader: missing %s\n", name); abort(); }
          return fn;
      }

      EGLBoolean eglLabUnload(void) {
          pthread_mutex_lock(&lock);
          if (live_contexts) { pthread_mutex_unlock(&lock); return EGL_FALSE; }
          if (module) {
              PFNEGLRELEASETHREADPROC release = resolve("eglReleaseThread");
              release();
              if (dlclose(module)) { pthread_mutex_unlock(&lock); return EGL_FALSE; }
              module = NULL;
          }
          pthread_mutex_unlock(&lock);
          return EGL_TRUE;
      }
    '';
    launcher = pkgs.writeText "launcher" ''
      #!@bash@
      set -euo pipefail
      # A watchdog restart must never claim NVIDIA while Windows owns it.
      while [[ $(@coreutils@/readlink -f /sys/bus/pci/devices/0000:01:00.0/driver) != */nvidia ]]; do
          @coreutils@/sleep 1
      done
      # If the patched compositor crashes, the stock watchdog requests safe mode.
      # Fall back to the normal compositor once NVIDIA is back on Linux.
      for argument in "$@"; do
          if [[ $argument == --safe-mode ]]; then
              export AQ_DRM_DEVICES=/dev/dri/nvidia-dgpu
              exec @stock@ "$@"
          fi
      done
      cards=()
      for pci in 0000:01:00.0 0000:00:02.0; do
          found=()
          for node in /sys/bus/pci/devices/$pci/drm/card*; do
              [[ ''${node##*/} =~ ^card[0-9]+$ ]] && found+=("/dev/dri/''${node##*/}")
          done
          [[ ''${#found[@]} == 1 ]] || { echo "Cannot identify the DRM card for $pci" >&2; exit 1; }
          cards+=("''${found[0]}")
      done
      export AQ_DRM_DEVICES="''${cards[0]}:''${cards[1]}"
      export HYPRLAND_MIGRATION_LAB=1 HYPRLAND_MIGRATION_PHYSICAL=1 HYPRLAND_MIGRATION_LAB_REALLOCATE=1
      unset HYPRLAND_MIGRATION_LAB_NESTED
      export HYPRLAND_LAB_REAL_EGL='@egl@'
      export __EGL_VENDOR_LIBRARY_DIRS=/run/opengl-driver/share/glvnd/egl_vendor.d
      export __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS=/run/opengl-driver/share/egl/egl_external_platform.d
      unset __EGL_VENDOR_LIBRARY_FILENAMES GBM_BACKEND __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME
      # main() restores the original search path before starting any child processes.
      export HYPRLAND_MIGRATION_CHILD_LD_LIBRARY_PATH="''${LD_LIBRARY_PATH-}"
      export LD_LIBRARY_PATH="@out@/lib:/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      exec @binary@ "$@"
    '';
    loader = pkgs.stdenv.mkDerivation {
      pname = "hyprland-private-egl-loader";
      version = "1";
      dontUnpack = true;
      nativeBuildInputs = [pkgs.python3 pkgs.pkg-config];
      buildInputs = [pkgs.libglvnd];
      buildPhase = ''
        cp ${eglGenerator} build-egl-loader.py
        cp ${eglPrefix} egl-loader-prefix.c
        mkdir build
        python3 build-egl-loader.py
        $CC -shared -fPIC -O1 -Wall -Wextra -Werror build/egl-loader.c \
          $(pkg-config --cflags egl) -ldl -pthread -Wl,-soname,libEGL.so.1 -o libEGL.so.1
      '';
      installPhase = ''
        install -Dm755 libEGL.so.1 $out/lib/libEGL.so.1
      '';
    };
  in
    pkgs.runCommand "hyprland-navis-preserve" {
      passthru = {
        inherit compositor aquamarine loader;
        providedSessions = ["hyprland"];
      };
      inherit (compositor) version;
      outputs = ["out" "man" "dev"];
      meta = stock.meta // {mainProgram = "Hyprland";};
    } ''
        mkdir -p $out/{bin,libexec,lib}
        ln -s ${compositor.man} $man
        ln -s ${compositor.dev} $dev
        ln -s ${compositor}/bin/.Hyprland-wrapped $out/libexec/Hyprland
        ln -s ${compositor}/bin/hyprctl $out/bin/hyprctl
        ln -s ${compositor}/bin/hyprpm $out/bin/hyprpm
        ln -s ${compositor}/share $out/share
        ln -s ${loader}/lib/libEGL.so.1 $out/lib/libEGL.so.1
        substitute ${launcher} $out/bin/Hyprland \
          --replace-fail '@bash@' '${pkgs.bash}/bin/bash' \
          --replace-fail '@out@' "$out" \
          --replace-fail '@coreutils@' '${pkgs.coreutils}/bin' \
          --replace-fail '@stock@' '${stock}/bin/Hyprland' \
          --replace-fail '@binary@' '${compositor}/bin/Hyprland' \
          --replace-fail '@egl@' '${lib.getLib pkgs.libglvnd}/lib/libEGL.so.1'
        cat > $out/bin/start-hyprland <<SCRIPT
      #!${pkgs.bash}/bin/bash
      exec ${stock}/bin/start-hyprland --no-nixgl --path $out/bin/Hyprland "\$@"
      SCRIPT
        chmod +x $out/bin/Hyprland $out/bin/start-hyprland
    ''
) {}
