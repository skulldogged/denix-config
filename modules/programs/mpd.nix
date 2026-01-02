{delib, ...}:
delib.module {
  name = "programs.mpd";

  options.programs.mpd = with delib; {
    enable = boolOption false;
    musicDirectory = strOption "/mnt/music";
  };

  home.ifEnabled = {myconfig, ...}: {
    services.mpd = {
      enable = true;
      musicDirectory = myconfig.programs.mpd.musicDirectory;
      extraConfig = ''
        audio_output {
          type "pipewire"
          name "PipeWire Output"
        }

        # For cava/visualizers
        audio_output {
          type "fifo"
          name "Visualizer feed"
          path "/tmp/mpd.fifo"
          format "44100:16:2"
        }
      '';
    };
  };
}
