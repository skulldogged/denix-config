{delib, ...}:
delib.module {
  name = "polaris";

  nixos.ifEnabled.services.glance = {
    enable = true;
    openFirewall = false;
    settings = {
      server = {
        host = "127.0.0.1";
        port = 5678;
      };

      theme = {
        background-color = "240 21 15";
        negative-color = "347 70 65";
        positive-color = "115 54 76";
        primary-color = "217 92 83";
      };

      pages = [
        {
          name = "Startpage";
          width = "slim";
          hide-desktop-navigation = true;
          center-vertically = true;
          columns = [
            {
              size = "full";
              widgets = [
                {
                  type = "search";
                  autofocus = true;
                }

                {
                  type = "monitor";
                  cache = "1m";
                  title = "Services";
                  sites = [
                    {
                      title = "Jellyfin";
                      url = "https://jellyfin.pupbrained.dev/";
                      icon = "si:jellyfin";
                    }
                    {
                      title = "Forgejo";
                      url = "https://git.pupbrained.dev/";
                      icon = "si:forgejo";
                    }
                    {
                      title = "Vaultwarden";
                      url = "https://vault.pupbrained.dev/";
                      icon = "si:vaultwarden";
                    }
                  ];
                }

                {
                  type = "bookmarks";
                  groups = [
                    {
                      title = "General";
                      links = [
                        {
                          title = "Gmail";
                          url = "https://mail.google.com/mail/u/0/";
                        }
                        {
                          title = "Amazon";
                          url = "https://www.amazon.com/";
                        }
                        {
                          title = "Github";
                          url = "https://github.com/";
                        }
                      ];
                    }
                    {
                      title = "Entertainment";
                      links = [
                        {
                          title = "YouTube";
                          url = "https://www.youtube.com/";
                        }
                        {
                          title = "Prime Video";
                          url = "https://www.primevideo.com/";
                        }
                        {
                          title = "Disney+";
                          url = "https://www.disneyplus.com/";
                        }
                      ];
                    }
                    {
                      title = "Social";
                      links = [
                        {
                          title = "Reddit";
                          url = "https://www.reddit.com/";
                        }
                        {
                          title = "Twitter";
                          url = "https://twitter.com/";
                        }
                        {
                          title = "Instagram";
                          url = "https://www.instagram.com/";
                        }
                      ];
                    }
                  ];
                }
              ];
            }
          ];
        }
      ];
    };
  };
}
