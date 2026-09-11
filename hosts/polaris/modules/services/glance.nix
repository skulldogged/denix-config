{delib, ...}: let
  # Add Twitch login names here when ready to show channel status.
  twitchChannels = ["hasanabi" "theo"];
  link = title: url: {inherit title url;};
in
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
            name = "Home";
            # Preserve existing links to the old start page.
            slug = "startpage";
            width = "default";
            center-vertically = true;
            hide-desktop-navigation = true;
            head-widgets = [
              {
                type = "search";
                autofocus = true;
                hide-header = true;
                search-engine = "kagi";
                placeholder = "Search with Kagi";
              }
            ];
            columns = [
              {
                size = "small";
                widgets = [
                  {
                    type = "clock";
                    hour-format = "12h";
                  }
                  {
                    type = "bookmarks";
                    title = "Apps";
                    groups = [
                      {
                        title = "Daily";
                        links = [
                          (link "Gmail" "https://mail.google.com/mail/u/0/")
                          (link "GitHub" "https://github.com/")
                          (link "Vaultwarden" "https://vault.pupbrained.dev/")
                        ];
                      }
                      {
                        title = "My tools";
                        links = [
                          (link "Home Assistant" "https://home.skulldogged.dev/")
                          (link "Forgejo" "https://git.pupbrained.dev/")
                          (link "Zipline" "https://zip.pupbrained.dev/")
                        ];
                      }
                      {
                        title = "Social";
                        links = [
                          (link "Twitter" "https://x.com/")
                          (link "Bluesky" "https://bsky.app/")
                          (link "Reddit" "https://www.reddit.com/")
                        ];
                      }
                    ];
                  }
                  {
                    type = "bookmarks";
                    title = "Media";
                    groups = [
                      {
                        title = "Watch";
                        links = [
                          (link "Jellyfin" "https://jellyfin.pupbrained.dev/")
                          (link "YouTube" "https://www.youtube.com/feed/subscriptions")
                        ];
                      }
                      {
                        title = "Library & downloads";
                        links = [
                          (link "slskd" "https://slskd.skulldogged.dev/")
                          (link "Cobalt" "https://cobalt.skulldogged.dev/")
                        ];
                      }
                    ];
                  }
                ];
              }
              {
                size = "full";
                widgets = [
                  {
                    type = "group";
                    widgets = [
                      {
                        type = "rss";
                        title = "Tech";
                        style = "vertical-list";
                        limit = 12;
                        collapse-after = 10;
                        cache = "30m";
                        feeds = [
                          (link "Ars Technica" "https://feeds.arstechnica.com/arstechnica/index")
                          (link "The Verge" "https://www.theverge.com/rss/index.xml")
                        ];
                      }
                      {
                        type = "rss";
                        title = "AI";
                        style = "vertical-list";
                        limit = 12;
                        collapse-after = 10;
                        cache = "30m";
                        feeds = [
                          (link "TechCrunch AI" "https://techcrunch.com/category/artificial-intelligence/feed/")
                          (link "Simon Willison" "https://simonwillison.net/atom/everything/")
                        ];
                      }
                      {
                        type = "hacker-news";
                        title = "Hacker News";
                        limit = 12;
                        collapse-after = 10;
                      }
                    ];
                  }
                ];
              }
              {
                size = "small";
                widgets = [
                  {
                    type = "calendar";
                    first-day-of-week = "sunday";
                  }
                  {
                    type = "twitch-channels";
                    title = "Twitch";
                    channels = twitchChannels;
                    sort-by = "live";
                    collapse-after = 5;
                  }
                  {
                    type = "monitor";
                    title = "Services";
                    style = "compact";
                    cache = "5m";
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
                      {
                        title = "Home Assistant";
                        url = "https://home.skulldogged.dev/";
                        icon = "si:homeassistant";
                      }
                      {
                        title = "Search";
                        url = "https://search.skulldogged.dev/";
                        icon = "si:searxng";
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
