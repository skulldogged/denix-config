{
  config,
  delib,
  lib,
  pkgs,
  ...
}: let
  espMountPoint = config.boot.loader.efi.efiSysMountPoint;
  expectedEspDevice = config.fileSystems.${espMountPoint}.device;
  visorBootManager = pkgs.local.visor-bootmanager;
  visorBackground = ../assets/visor/shiny-espeon.gif;
  visorNixosIcon = pkgs.runCommand "visor-nixos-icon.png" {nativeBuildInputs = [pkgs.imagemagick];} ''
    magick \
      ${pkgs.nixos-icons}/share/icons/hicolor/128x128/apps/nix-snowflake.png \
      -depth 8 \
      PNG32:$out
  '';
  visorWindowsIcon = pkgs.runCommand "visor-windows-icon.png" {nativeBuildInputs = [pkgs.imagemagick];} ''
    magick \
      ${visorBootManager}/share/visor/icons/windows.png \
      -trim \
      +repage \
      -resize '112x112' \
      -channel RGB \
      -fill '#0078D4' \
      -colorize 100% \
      +channel \
      -background none \
      -gravity center \
      -extent 128x128 \
      -depth 8 \
      PNG32:$out
  '';

  visorConfigHeader = pkgs.writeText "navis-visor-boot.conf" ''
    timeout=10
    default=0
    quiet=0
    editor=0
    remember_last=0

    scan=quick
    hotplug=0
    scan_existing=0
    recovery_entries=0
    snapshots=0

    resolution=native
    title=none
    logo=none
    show_names=1
    center_info=0
    entries_per_page=2
    box_radius=14
    mouse=1
    font=maple
    log=1

    title_color=A6E3A1
    name_color=CDD6F4
    highlight_color=A6E3A1
    info_color=A6ADC8
    bg_color=1E1E2E
    blur=clear
    blur_title=1
    blur_color=313244
    animation=1
    anim_speed=8
    fade_speed=10

    icon_size=112
    icon_spacing=72
    underline_color=A6E3A1
    underline_thickness=6

    power_position=bottomright
    shutdown_color=F38BA8
    reboot_color=F9E2AF
    firmware_color=94E2D5
    power_icons=1
    shutdown_icon=\EFI\visor\icons\power_shutdown.png
    reboot_icon=\EFI\visor\icons\power_reboot.png
    firmware_icon=\EFI\visor\icons\power_bios.png

    background=\EFI\visor\backgrounds\shiny-espeon.gif
  '';

  visorSync = pkgs.writeShellApplication {
    name = "navis-visor-sync";

    runtimeInputs = [
      pkgs.coreutils
      pkgs.efibootmgr
      pkgs.findutils
      pkgs.sbsigntool
      pkgs.util-linux
    ];

    text = ''
      set -euo pipefail

      esp=${lib.escapeShellArg espMountPoint}
      sign=1

      while (($#)); do
        case "$1" in
          --esp)
            [[ $# -ge 2 ]] || {
              echo "navis-visor-sync: --esp requires a path" >&2
              exit 2
            }
            esp="$2"
            shift 2
            ;;
          --unsigned-test)
            sign=0
            shift
            ;;
          *)
            echo "navis-visor-sync: unknown argument: $1" >&2
            exit 2
            ;;
        esac
      done

      if ((sign)); then
        expected_source="$(${pkgs.coreutils}/bin/readlink -f ${lib.escapeShellArg expectedEspDevice})"
        actual_source="$(${pkgs.coreutils}/bin/readlink -f "$(findmnt -n -o SOURCE --target "$esp")")"
        actual_fs="$(findmnt -n -o FSTYPE --target "$esp")"

        if [[ "$actual_source" != "$expected_source" || "$actual_fs" != vfat ]]; then
          echo "navis-visor-sync: refusing unexpected ESP at $esp ($actual_source, $actual_fs)" >&2
          exit 1
        fi
      elif [[ "$(${pkgs.coreutils}/bin/readlink -f "$esp")" == "$(${pkgs.coreutils}/bin/readlink -f ${lib.escapeShellArg espMountPoint})" ]]; then
        echo "navis-visor-sync: refusing an unsigned install to the real ESP" >&2
        exit 1
      fi

      uki_dir="$esp/EFI/Linux"
      visor_dir="$esp/EFI/visor"
      [[ -d "$uki_dir" ]] || {
        echo "navis-visor-sync: Lanzaboote UKI directory is missing: $uki_dir" >&2
        exit 1
      }

      mapfile -t ukis < <(
        find "$uki_dir" -maxdepth 1 -type f \
          -name 'nixos-generation-*.efi' -printf '%f\n' \
          | sort -t- -k3,3nr -k1,1
      )
      ((''${#ukis[@]} > 0)) || {
        echo "navis-visor-sync: no Lanzaboote UKIs found in $uki_dir" >&2
        exit 1
      }

      install -d -m0755 \
        "$visor_dir/icons" \
        "$visor_dir/backgrounds"

      for asset in ${visorBootManager}/share/visor/icons/*.png; do
        install -m0644 "$asset" "$visor_dir/icons/$(basename "$asset")"
      done
      install -m0644 ${visorNixosIcon} "$visor_dir/icons/nixos.png"
      install -m0644 ${visorWindowsIcon} "$visor_dir/icons/windows.png"
      for asset in ${visorBootManager}/share/visor/backgrounds/*.png; do
        install -m0644 "$asset" "$visor_dir/backgrounds/$(basename "$asset")"
      done
      install -m0644 ${visorBackground} "$visor_dir/backgrounds/shiny-espeon.gif"
      install -m0644 ${visorBootManager}/share/visor/logo.png "$visor_dir/logo.png"

      efi_tmp="$(mktemp "$visor_dir/.visor_x64.efi.XXXXXX")"
      config_tmp="$(mktemp "$visor_dir/.boot.conf.XXXXXX")"
      cleanup() {
        rm -f "$efi_tmp" "$config_tmp"
      }
      trap cleanup EXIT

      if ((sign)); then
        sbsign \
          --key ${lib.escapeShellArg (toString config.boot.lanzaboote.privateKeyFile)} \
          --cert ${lib.escapeShellArg (toString config.boot.lanzaboote.publicKeyFile)} \
          --output "$efi_tmp" \
          ${visorBootManager}/lib/visor/visor_x64.efi
        sbverify \
          --cert ${lib.escapeShellArg (toString config.boot.lanzaboote.publicKeyFile)} \
          "$efi_tmp"
      else
        install -m0644 ${visorBootManager}/lib/visor/visor_x64.efi "$efi_tmp"
      fi
      chmod 0644 "$efi_tmp"

      install -m0644 ${visorConfigHeader} "$config_tmp"

      append_nixos_entry() {
        local uki="$1"
        local generation
        local display_name

        if [[ "$uki" =~ ^nixos-generation-([0-9]+)- ]]; then
          generation="''${BASH_REMATCH[1]}"
        else
          return
        fi

        if [[ "''${2:-0}" == 1 ]]; then
          display_name=NixOS
        else
          display_name="NixOS - Generation $generation"
        fi

        cat >>"$config_tmp" <<EOF

      entry {
          name = "$display_name"
          icon = \\EFI\\visor\\icons\\nixos.png
          color = A6E3A1
          kernel = \\EFI\\Linux\\$uki
      }
      EOF
        generated=$((generated + 1))
      }

      generated=0
      append_nixos_entry "''${ukis[0]}" 1

      if [[ -f "$esp/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
        cat >>"$config_tmp" <<'EOF'

      entry {
          name = "Windows"
          icon = \EFI\visor\icons\windows.png
          color = 89B4FA
          kernel = \EFI\Microsoft\Boot\bootmgfw.efi
      }
      EOF
      fi

      for uki in "''${ukis[@]:1}"; do
        append_nixos_entry "$uki"
      done

      ((generated > 0)) || {
        echo "navis-visor-sync: no valid Lanzaboote generation names found" >&2
        exit 1
      }

      if [[ -f "$esp/EFI/systemd/systemd-bootx64.efi" ]]; then
        cat >>"$config_tmp" <<'EOF'

      entry {
          name = "systemd-boot fallback"
          icon = \EFI\visor\icons\linux.png
          color = F9E2AF
          kernel = \EFI\systemd\systemd-bootx64.efi
      }
      EOF
      fi

      mv -f "$efi_tmp" "$visor_dir/visor_x64.efi"
      mv -f "$config_tmp" "$visor_dir/boot.conf"
      [[ -e "$visor_dir/boot.log" ]] || install -m0644 /dev/null "$visor_dir/boot.log"
      sync -f "$esp"

      if ((sign)); then
        efi_state="$(efibootmgr)"
        visor_id=""

        while IFS= read -r line; do
          if [[ "$line" =~ ^Boot([0-9A-Fa-f]{4})[*]?[[:space:]]+Visor([[:space:]]|$) ]]; then
            visor_id="''${BASH_REMATCH[1]^^}"
            break
          fi
        done <<<"$efi_state"

        if [[ -z "$visor_id" ]]; then
          esp_parent="$(lsblk -ndo PKNAME "$actual_source" | head -n1)"
          esp_part="$(lsblk -ndo PARTN "$actual_source" | head -n1)"

          if [[ -z "$esp_parent" || ! "$esp_part" =~ ^[0-9]+$ || ! -b "/dev/$esp_parent" ]]; then
            echo "navis-visor-sync: cannot resolve the ESP disk and partition for an EFI entry" >&2
            exit 1
          fi

          efibootmgr \
            --create \
            --disk "/dev/$esp_parent" \
            --part "$esp_part" \
            --label Visor \
            --loader '\EFI\visor\visor_x64.efi'

          efi_state="$(efibootmgr)"
          while IFS= read -r line; do
            if [[ "$line" =~ ^Boot([0-9A-Fa-f]{4})[*]?[[:space:]]+Visor([[:space:]]|$) ]]; then
              visor_id="''${BASH_REMATCH[1]^^}"
              break
            fi
          done <<<"$efi_state"
        fi

        if [[ -z "$visor_id" ]]; then
          echo "navis-visor-sync: Visor EFI entry is still missing after creation" >&2
          exit 1
        fi

        boot_order=""
        while IFS= read -r line; do
          if [[ "$line" == "BootOrder: "* ]]; then
            boot_order="''${line#BootOrder: }"
            break
          fi
        done <<<"$efi_state"

        if [[ -z "$boot_order" ]]; then
          echo "navis-visor-sync: firmware did not report a BootOrder" >&2
          exit 1
        fi

        new_order="$visor_id"
        IFS=',' read -r -a boot_ids <<<"$boot_order"
        for boot_id in "''${boot_ids[@]}"; do
          boot_id="''${boot_id//[[:space:]]/}"
          if [[ -n "$boot_id" && "''${boot_id^^}" != "$visor_id" ]]; then
            new_order+=",''${boot_id^^}"
          fi
        done

        if [[ "$boot_order" != "$new_order" ]]; then
          efibootmgr --bootorder "$new_order"
        fi
      fi

      trap - EXIT
      echo "navis-visor-sync: installed $generated NixOS generation(s) into $visor_dir"
    '';
  };

  navisBootInstall = pkgs.writeShellApplication {
    name = "navis-boot-install";

    text = ''
      set -euo pipefail

      # Lanzaboote remains responsible for synthesizing and signing the UKIs.
      PATH=${config.systemd.package}/lib/systemd:$PATH
      ${config.boot.lanzaboote.installCommand} \
        ${lib.escapeShellArg "--public-key=${toString config.boot.lanzaboote.publicKeyFile}"} \
        ${lib.escapeShellArg "--private-key=${toString config.boot.lanzaboote.privateKeyFile}"} \
        ${lib.escapeShellArg espMountPoint} \
        /nix/var/nix/profiles/system-*-link

      # Visor is the first-stage menu over the UKIs Lanzaboote just installed.
      ${lib.getExe visorSync}
    '';
  };
in
  delib.module {
    name = "navis";

    nixos.ifEnabled = {
      assertions = [
        {
          assertion = config.boot.lanzaboote.extraEfiSysMountPoints == [];
          message = "navis Visor integration currently supports one EFI system partition";
        }
        {
          assertion = !config.boot.lanzaboote.measuredBoot.enable;
          message = "navis Visor integration must be extended before enabling Lanzaboote measured boot";
        }
      ];

      boot.loader.external.installHook = lib.mkForce (lib.getExe navisBootInstall);

      environment.systemPackages = [
        visorSync
      ];
    };
  }
