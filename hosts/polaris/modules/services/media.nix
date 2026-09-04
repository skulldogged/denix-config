{
  config,
  delib,
  pkgs,
  ...
}: let
  lidarrDataDir = "/var/lib/lidarr/.config/Lidarr";
  lidarrPluginDir = "${lidarrDataDir}/plugins/allquiet-hub/Lidarr.Plugin.Slskd";
  gamdlBridgePort = 8787;
  gamdlDownloadDir = "/mnt/downloads/gamdl";
  slskdDownloadDir = "/mnt/downloads/slskd";

  lidarrSlskdBootstrap = pkgs.writeShellApplication {
    name = "lidarr-slskd-bootstrap";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnused
      pkgs.jq
    ];
    text = ''
      runtime_dir="$RUNTIME_DIRECTORY"
      lidarr_config="''${LIDARR_CONFIG:-${lidarrDataDir}/config.xml}"
      lidarr_api_url="''${LIDARR_API_URL:-http://127.0.0.1:8686/api/v1}"
      slskd_key_source="''${SLSKD_KEY_FILE:-${config.sops.secrets.slskd_api_key.path}}"
      slskd_application_url="''${SLSKD_APPLICATION_URL:-http://127.0.0.1:5030/api/v0/application}"
      gamdl_bridge_url="''${GAMDL_BRIDGE_URL:-http://127.0.0.1:${toString gamdlBridgePort}}"
      slskd_key_file="$runtime_dir/slskd-api-key"
      curl_config="$runtime_dir/curl.conf"
      slskd_curl_config="$runtime_dir/slskd-curl.conf"
      catalog_refresh_marker="${lidarrDataDir}/.official-release-catalog-state"
      catalog_refresh_version="official-release-catalog-v1"
      command_poll_attempts=900
      punctuation_migration_marker="${lidarrDataDir}/.punctuation-migration-v1"

      install -m 0600 "$slskd_key_source" "$slskd_key_file"
      slskd_api_key=$(tr -d '\r\n' < "$slskd_key_file")
      if [[ -z "$slskd_api_key" ]]; then
        echo "The slskd API key is empty" >&2
        exit 1
      fi
      printf 'header = "X-API-Key: %s"\n' "$slskd_api_key" > "$slskd_curl_config"
      chmod 0600 "$slskd_curl_config"
      unset slskd_api_key

      slskd_ready=0
      for _ in $(seq 1 60); do
        if curl --config "$slskd_curl_config" --silent --fail \
          --connect-timeout 1 --max-time 2 --output /dev/null \
          "$slskd_application_url"
        then
          slskd_ready=1
          break
        fi
        sleep 1
      done
      if [[ "$slskd_ready" != 1 ]]; then
        echo "slskd did not accept its API key within 60 seconds" >&2
        exit 1
      fi

      gamdl_bridge_ready=0
      for _ in $(seq 1 180); do
        if curl --silent --fail --connect-timeout 1 --max-time 2 \
          --output /dev/null \
          "$gamdl_bridge_url/health"
        then
          gamdl_bridge_ready=1
          break
        fi
        sleep 1
      done
      if [[ "$gamdl_bridge_ready" != 1 ]]; then
        echo "The gamdl bridge did not become ready within 180 seconds" >&2
        exit 1
      fi

      lidarr_api_key=""
      for _ in $(seq 1 120); do
        if [[ -s "$lidarr_config" ]]; then
          lidarr_api_key=$(sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$lidarr_config" | head -n 1)
        fi

        if [[ -n "$lidarr_api_key" ]]; then
          printf 'header = "X-Api-Key: %s"\n' "$lidarr_api_key" > "$curl_config"
          chmod 0600 "$curl_config"
          if curl --config "$curl_config" --silent --fail \
            --connect-timeout 1 --max-time 2 --output /dev/null \
            "$lidarr_api_url/system/status"
          then
            break
          fi
        fi
        sleep 1
      done

      if [[ -z "$lidarr_api_key" ]] || ! curl --config "$curl_config" \
        --silent --fail --connect-timeout 1 --max-time 2 \
        --output /dev/null "$lidarr_api_url/system/status"
      then
        echo "Lidarr API did not become ready within 120 seconds" >&2
        exit 1
      fi

      curl_lidarr() {
        curl --config "$curl_config" --silent --show-error --fail-with-body "$@"
      }

      api_get() {
        curl_lidarr "$lidarr_api_url/$1"
      }

      api_write() {
        local method=$1
        local endpoint=$2
        local body=$3
        curl_lidarr \
          --request "$method" \
          --header 'Content-Type: application/json' \
          --data-binary "@$body" \
          "$lidarr_api_url/$endpoint"
      }

      run_command() {
        local body=$1
        local label=$2
        local command_id
        local command_status

        api_write POST command "$body" > "$runtime_dir/command-response.json"
        command_id=$(jq -er .id "$runtime_dir/command-response.json")

        for _ in $(seq 1 "$command_poll_attempts"); do
          api_get "command/$command_id" > "$runtime_dir/command-status.json"
          command_status=$(jq -r .status "$runtime_dir/command-status.json")
          case "$command_status" in
            completed)
              return 0
              ;;
            failed)
              echo "Lidarr command failed: $label" >&2
              return 1
              ;;
          esac
          sleep 1
        done

        echo "Lidarr command timed out: $label" >&2
        return 1
      }

      api_get downloadclient/schema > "$runtime_dir/download-client-schemas.json"
      jq -e '.[] | select(.implementation == "Slskd")' \
        "$runtime_dir/download-client-schemas.json" \
        > "$runtime_dir/download-client-schema.json"
      api_get downloadclient > "$runtime_dir/download-clients.json"
      download_client_id=$(jq -r \
        '[.[] | select(.implementation == "Slskd" and (.name | ascii_downcase) == "slskd")][0].id // empty' \
        "$runtime_dir/download-clients.json")

      if [[ -z "$download_client_id" ]]; then
        jq --rawfile slskdApiKey "$slskd_key_file" '
          ($slskdApiKey | sub("[\\r\\n]+$"; "")) as $apiKey |
          .name = "slskd" |
          .enable = true |
          .removeCompletedDownloads = true |
          .removeFailedDownloads = true |
          (.fields[] | select(.name == "host") | .value) = "127.0.0.1" |
          (.fields[] | select(.name == "port") | .value) = 5030 |
          (.fields[] | select(.name == "urlBase") | .value) = null |
          (.fields[] | select(.name == "useSsl") | .value) = false |
          (.fields[] | select(.name == "apiKey") | .value) = $apiKey |
          (.fields[] | select(.name == "repairConfiguration") | .value) = false
        ' "$runtime_dir/download-client-schema.json" \
          > "$runtime_dir/download-client-create.json"
        api_write POST downloadclient "$runtime_dir/download-client-create.json" \
          > "$runtime_dir/download-client.json"
        download_client_id=$(jq -r .id "$runtime_dir/download-client.json")
      else
        api_get "downloadclient/$download_client_id" > "$runtime_dir/download-client.json"
      fi

      jq --rawfile slskdApiKey "$slskd_key_file" '
        ($slskdApiKey | sub("[\\r\\n]+$"; "")) as $apiKey |
        .name = "slskd" |
        .enable = true |
        .removeCompletedDownloads = true |
        .removeFailedDownloads = true |
        (.fields[] | select(.name == "host") | .value) = "127.0.0.1" |
        (.fields[] | select(.name == "port") | .value) = 5030 |
        (.fields[] | select(.name == "urlBase") | .value) = null |
        (.fields[] | select(.name == "useSsl") | .value) = false |
        (.fields[] | select(.name == "apiKey") | .value) = $apiKey |
        (.fields[] | select(.name == "repairConfiguration") | .value) = false
      ' "$runtime_dir/download-client.json" \
        > "$runtime_dir/download-client-update.json"
      api_write PUT "downloadclient/$download_client_id" \
        "$runtime_dir/download-client-update.json" > /dev/null
      api_get "downloadclient/$download_client_id" \
        > "$runtime_dir/download-client-configured.json"
      api_write POST downloadclient/test "$runtime_dir/download-client-configured.json" \
        > /dev/null

      jq -e '.[] | select(.implementation == "Sabnzbd")' \
        "$runtime_dir/download-client-schemas.json" \
        > "$runtime_dir/gamdl-download-client-schema.json"
      api_get downloadclient > "$runtime_dir/download-clients.json"
      gamdl_download_client_id=$(jq -r '
        [
          .[] |
          select(
            .implementation == "Sabnzbd" and
            (.name | ascii_downcase) == "gamdl"
          )
        ][0].id // empty
      ' "$runtime_dir/download-clients.json")

      if [[ -z "$gamdl_download_client_id" ]]; then
        jq \
          --rawfile gamdlApiKey "$slskd_key_file" \
          --argjson gamdlPort "${toString gamdlBridgePort}" '
          ($gamdlApiKey | sub("[\\r\\n]+$"; "")) as $apiKey |
          .name = "gamdl" |
          .enable = true |
          .removeCompletedDownloads = true |
          .removeFailedDownloads = true |
          (.fields[] | select(.name == "host") | .value) = "127.0.0.1" |
          (.fields[] | select(.name == "port") | .value) = $gamdlPort |
          (.fields[] | select(.name == "useSsl") | .value) = false |
          (.fields[] | select(.name == "urlBase") | .value) = "/api/sabnzbd" |
          (.fields[] | select(.name == "apiKey") | .value) = $apiKey |
          (.fields[] | select(.name == "musicCategory") | .value) = "music"
        ' "$runtime_dir/gamdl-download-client-schema.json" \
          > "$runtime_dir/gamdl-download-client-create.json"
        api_write POST downloadclient \
          "$runtime_dir/gamdl-download-client-create.json" \
          > "$runtime_dir/gamdl-download-client.json"
        gamdl_download_client_id=$(jq -er .id \
          "$runtime_dir/gamdl-download-client.json")
      else
        api_get "downloadclient/$gamdl_download_client_id" \
          > "$runtime_dir/gamdl-download-client.json"
      fi

      jq \
        --rawfile gamdlApiKey "$slskd_key_file" \
        --argjson gamdlPort "${toString gamdlBridgePort}" '
        ($gamdlApiKey | sub("[\\r\\n]+$"; "")) as $apiKey |
        .name = "gamdl" |
        .enable = true |
        .removeCompletedDownloads = true |
        .removeFailedDownloads = true |
        (.fields[] | select(.name == "host") | .value) = "127.0.0.1" |
        (.fields[] | select(.name == "port") | .value) = $gamdlPort |
        (.fields[] | select(.name == "useSsl") | .value) = false |
        (.fields[] | select(.name == "urlBase") | .value) = "/api/sabnzbd" |
        (.fields[] | select(.name == "apiKey") | .value) = $apiKey |
        (.fields[] | select(.name == "musicCategory") | .value) = "music"
      ' "$runtime_dir/gamdl-download-client.json" \
        > "$runtime_dir/gamdl-download-client-update.json"
      api_write PUT "downloadclient/$gamdl_download_client_id" \
        "$runtime_dir/gamdl-download-client-update.json" > /dev/null
      api_get "downloadclient/$gamdl_download_client_id" \
        > "$runtime_dir/gamdl-download-client-configured.json"
      api_write POST downloadclient/test \
        "$runtime_dir/gamdl-download-client-configured.json" > /dev/null

      api_get indexer/schema > "$runtime_dir/indexer-schemas.json"
      jq -e '.[] | select(.implementation == "Slskd")' \
        "$runtime_dir/indexer-schemas.json" > "$runtime_dir/indexer-schema.json"
      api_get indexer > "$runtime_dir/indexers.json"
      indexer_id=$(jq -r \
        '[.[] | select(.implementation == "Slskd" and (.name | ascii_downcase) == "slskd")][0].id // empty' \
        "$runtime_dir/indexers.json")

      if [[ -z "$indexer_id" ]]; then
        jq --rawfile slskdApiKey "$slskd_key_file" '
          ($slskdApiKey | sub("[\\r\\n]+$"; "")) as $apiKey |
          .name = "slskd" |
          .enableRss = false |
          .enableAutomaticSearch = true |
          .enableInteractiveSearch = true |
          (.fields[] | select(.name == "baseUrl") | .value) = "http://127.0.0.1:5030/" |
          (.fields[] | select(.name == "apiKey") | .value) = $apiKey
        ' "$runtime_dir/indexer-schema.json" > "$runtime_dir/indexer-create.json"
        api_write POST indexer "$runtime_dir/indexer-create.json" \
          > "$runtime_dir/indexer.json"
        indexer_id=$(jq -r .id "$runtime_dir/indexer.json")
      else
        api_get "indexer/$indexer_id" > "$runtime_dir/indexer.json"
      fi

      jq --rawfile slskdApiKey "$slskd_key_file" '
        ($slskdApiKey | sub("[\\r\\n]+$"; "")) as $apiKey |
        .name = "slskd" |
        .enableRss = false |
        .enableAutomaticSearch = true |
        .enableInteractiveSearch = true |
        (.fields[] | select(.name == "baseUrl") | .value) = "http://127.0.0.1:5030/" |
        (.fields[] | select(.name == "apiKey") | .value) = $apiKey
      ' "$runtime_dir/indexer.json" > "$runtime_dir/indexer-update.json"
      api_write PUT "indexer/$indexer_id" \
        "$runtime_dir/indexer-update.json" > /dev/null
      api_get "indexer/$indexer_id" > "$runtime_dir/indexer-configured.json"
      api_write POST indexer/test "$runtime_dir/indexer-configured.json" > /dev/null

      jq -e '.[] | select(.implementation == "Newznab")' \
        "$runtime_dir/indexer-schemas.json" \
        > "$runtime_dir/gamdl-indexer-schema.json"
      api_get indexer > "$runtime_dir/indexers.json"
      gamdl_indexer_id=$(jq -r '
        [
          .[] |
          select(
            .implementation == "Newznab" and
            (.name | ascii_downcase) == "gamdl (apple music)"
          )
        ][0].id // empty
      ' "$runtime_dir/indexers.json")

      if [[ -z "$gamdl_indexer_id" ]]; then
        jq \
          --arg baseUrl "$gamdl_bridge_url/" \
          --rawfile gamdlApiKey "$slskd_key_file" \
          --argjson downloadClientId "$gamdl_download_client_id" '
          ($gamdlApiKey | sub("[\\r\\n]+$"; "")) as $apiKey |
          .name = "gamdl (Apple Music)" |
          .enableRss = false |
          .enableAutomaticSearch = true |
          .enableInteractiveSearch = true |
          .downloadClientId = $downloadClientId |
          (.fields[] | select(.name == "baseUrl") | .value) = $baseUrl |
          (.fields[] | select(.name == "apiPath") | .value) = "/api/lidarr" |
          (.fields[] | select(.name == "apiKey") | .value) = $apiKey |
          (.fields[] | select(.name == "categories") | .value) = [3010, 3040]
        ' "$runtime_dir/gamdl-indexer-schema.json" \
          > "$runtime_dir/gamdl-indexer-create.json"
        api_write POST indexer "$runtime_dir/gamdl-indexer-create.json" \
          > "$runtime_dir/gamdl-indexer.json"
        gamdl_indexer_id=$(jq -er .id "$runtime_dir/gamdl-indexer.json")
      else
        api_get "indexer/$gamdl_indexer_id" \
          > "$runtime_dir/gamdl-indexer.json"
      fi

      jq \
        --arg baseUrl "$gamdl_bridge_url/" \
        --rawfile gamdlApiKey "$slskd_key_file" \
        --argjson downloadClientId "$gamdl_download_client_id" '
        ($gamdlApiKey | sub("[\\r\\n]+$"; "")) as $apiKey |
        .name = "gamdl (Apple Music)" |
        .enableRss = false |
        .enableAutomaticSearch = true |
        .enableInteractiveSearch = true |
        .downloadClientId = $downloadClientId |
        (.fields[] | select(.name == "baseUrl") | .value) = $baseUrl |
        (.fields[] | select(.name == "apiPath") | .value) = "/api/lidarr" |
        (.fields[] | select(.name == "apiKey") | .value) = $apiKey |
        (.fields[] | select(.name == "categories") | .value) = [3010, 3040]
      ' "$runtime_dir/gamdl-indexer.json" \
        > "$runtime_dir/gamdl-indexer-update.json"
      api_write PUT "indexer/$gamdl_indexer_id" \
        "$runtime_dir/gamdl-indexer-update.json" > /dev/null
      api_get "indexer/$gamdl_indexer_id" \
        > "$runtime_dir/gamdl-indexer-configured.json"
      api_write POST indexer/test "$runtime_dir/gamdl-indexer-configured.json" \
        > /dev/null

      api_get delayprofile > "$runtime_dir/delay-profiles.json"
      delay_profile_id=$(jq -er \
        '([.[] | select(.name == "Default" and ((.tags // []) | length == 0))][0].id // .[0].id)' \
        "$runtime_dir/delay-profiles.json")
      api_get "delayprofile/$delay_profile_id" > "$runtime_dir/delay-profile.json"
      if ! jq -e '.items | any(.protocol == "SlskdDownloadProtocol")' \
        "$runtime_dir/delay-profile.json" > /dev/null
      then
        echo "Lidarr delay profile $delay_profile_id is missing the Slskd protocol" >&2
        exit 1
      fi
      if ! jq -e '.items | any(.protocol == "UsenetDownloadProtocol")' \
        "$runtime_dir/delay-profile.json" > /dev/null
      then
        echo "Lidarr delay profile $delay_profile_id is missing the Usenet protocol" >&2
        exit 1
      fi
      jq '
        (.items[] |
          select(
            .protocol == "SlskdDownloadProtocol" or
            .protocol == "UsenetDownloadProtocol"
          ) |
          .allowed
        ) = true
      ' \
        "$runtime_dir/delay-profile.json" > "$runtime_dir/delay-profile-update.json"
      api_write PUT "delayprofile/$delay_profile_id" \
        "$runtime_dir/delay-profile-update.json" > /dev/null

      quality_profile_name="Lossless"
      api_get qualityprofile > "$runtime_dir/quality-profiles.json"
      quality_profile_id=$(jq -er --arg profileName "$quality_profile_name" '
        [ .[] | select(.name == $profileName) ] as $matches |
        if ($matches | length) == 1 then
          $matches[0].id
        else
          error("the built-in Lossless quality profile is not unique")
        end
      ' "$runtime_dir/quality-profiles.json")
      api_get "qualityprofile/$quality_profile_id" \
        > "$runtime_dir/quality-profile-existing.json"
      api_get qualityprofile/schema > "$runtime_dir/quality-profile-schema.json"

      jq --arg profileName "$quality_profile_name" \
        --argjson existingId "$quality_profile_id" \
        --slurpfile existing "$runtime_dir/quality-profile-existing.json" '
        def leaves:
          [
            .items[] |
            if .quality != null then
              .
            else
              .items[]
            end |
            .id = 0 |
            .name = null |
            .items = [] |
            .allowed = false
          ];

        ([.items[] | select(.quality == null) | .id] | max) + 1 as $standardGroupId |
        $standardGroupId + 1 as $hiResGroupId |
        leaves as $leaves |
        ([9, 10, 12, 11] | map(
          . as $qualityId |
          $leaves[] |
          select(.quality.id == $qualityId) |
          .allowed = true
        )) as $aacFallback |
        ($leaves | map(
          select(
            .quality.id == 6 or
            .quality.id == 7 or
            .quality.id == 35 or
            .quality.id == 36
          ) |
          .allowed = true
        )) as $standardLossless |
        ($leaves | map(
          select(.quality.id == 21 or .quality.id == 37) |
          .allowed = true
        )) as $hiResLossless |
        .id = $existingId |
        .name = $profileName |
        .upgradeAllowed = false |
        .cutoff = $standardGroupId |
        .minFormatScore = 0 |
        .cutoffFormatScore = 0 |
        .formatItems = $existing[0].formatItems |
        .items = (
          ($leaves | map(select(
            .quality.id != 6 and
            .quality.id != 7 and
            .quality.id != 9 and
            .quality.id != 10 and
            .quality.id != 11 and
            .quality.id != 12 and
            .quality.id != 21 and
            .quality.id != 35 and
            .quality.id != 36 and
            .quality.id != 37
          ))) +
          $aacFallback +
          [
            {
              id: $standardGroupId,
              name: "Standard Lossless",
              quality: null,
              items: $standardLossless,
              allowed: true
            },
            {
              id: $hiResGroupId,
              name: "Hi-Res Lossless",
              quality: null,
              items: $hiResLossless,
              allowed: true
            }
          ]
        )
      ' "$runtime_dir/quality-profile-schema.json" \
        > "$runtime_dir/quality-profile-managed.json"

      api_write PUT "qualityprofile/$quality_profile_id" \
        "$runtime_dir/quality-profile-managed.json" > /dev/null

      api_get "qualityprofile/$quality_profile_id" \
        > "$runtime_dir/quality-profile-configured.json"
      jq -e '
        def allowed_leaf_ids:
          [
            .items[] |
            select(.allowed) |
            if .quality != null then
              .quality.id
            else
              .items[] | select(.allowed) | .quality.id
            end
          ] | sort;
        .upgradeAllowed == false and
        .name == "Lossless" and
        allowed_leaf_ids == [6, 7, 9, 10, 11, 12, 21, 35, 36, 37] and
        [.items[-6].quality.id, .items[-5].quality.id, .items[-4].quality.id, .items[-3].quality.id] == [9, 10, 12, 11] and
        .items[-2].name == "Standard Lossless" and
        ([.items[-2].items[].quality.id] | sort) == [6, 7, 35, 36] and
        .items[-1].name == "Hi-Res Lossless" and
        ([.items[-1].items[].quality.id] | sort) == [21, 37] and
        .cutoff == .items[-2].id
      ' "$runtime_dir/quality-profile-configured.json" > /dev/null

      metadata_profile_name="All Official Releases"
      api_get metadataprofile > "$runtime_dir/metadata-profiles.json"
      metadata_profile_id=$(jq -r --arg profileName "$metadata_profile_name" '
        [ .[] | select(.name == $profileName) ] as $matches |
        if ($matches | length) > 1 then
          error("duplicate managed metadata profiles")
        else
          $matches[0].id // empty
        end
      ' "$runtime_dir/metadata-profiles.json")
      metadata_profile_changed=1
      if [[ -n "$metadata_profile_id" ]]; then
        api_get "metadataprofile/$metadata_profile_id" \
          > "$runtime_dir/metadata-profile-existing.json"
        if jq -e '
          all(.primaryAlbumTypes[]; .allowed) and
          all(.secondaryAlbumTypes[]; .allowed) and
          ([.releaseStatuses[] | select(.allowed) | .releaseStatus.name] == ["Official"])
        ' "$runtime_dir/metadata-profile-existing.json" > /dev/null
        then
          metadata_profile_changed=0
        fi
      fi
      standard_metadata_profile_id=$(jq -er '
        [ .[] | select(.name == "Standard") ] as $matches |
        if ($matches | length) == 1 then
          $matches[0].id
        else
          error("standard metadata profile is not unique")
        end
      ' "$runtime_dir/metadata-profiles.json")
      api_get "metadataprofile/$standard_metadata_profile_id" \
        > "$runtime_dir/metadata-profile-template.json"
      jq --arg profileName "$metadata_profile_name" \
        --argjson existingId "''${metadata_profile_id:-0}" '
        .id = $existingId |
        .name = $profileName |
        .primaryAlbumTypes |= map(.allowed = true) |
        .secondaryAlbumTypes |= map(.allowed = true) |
        .releaseStatuses |= map(
          .allowed = (.releaseStatus.name == "Official")
        )
      ' "$runtime_dir/metadata-profile-template.json" \
        > "$runtime_dir/metadata-profile-managed.json"

      if ((metadata_profile_changed > 0)); then
        if [[ -e "$catalog_refresh_marker" && ! -f "$catalog_refresh_marker" ]]; then
          echo "Catalog refresh marker is not a regular file: $catalog_refresh_marker" >&2
          exit 1
        fi
        printf 'pending\n' > "$catalog_refresh_marker"
        chmod 0600 "$catalog_refresh_marker"
      fi

      if [[ -z "$metadata_profile_id" ]]; then
        api_write POST metadataprofile "$runtime_dir/metadata-profile-managed.json" > /dev/null
      else
        api_write PUT "metadataprofile/$metadata_profile_id" \
          "$runtime_dir/metadata-profile-managed.json" > /dev/null
      fi

      metadata_profile_id=$(api_get metadataprofile | jq -er \
        --arg profileName "$metadata_profile_name" '
          [ .[] | select(.name == $profileName) ] as $matches |
          if ($matches | length) == 1 then
            $matches[0].id
          else
            error("managed metadata profile was not created uniquely")
          end
        ')
      api_get "metadataprofile/$metadata_profile_id" \
        > "$runtime_dir/metadata-profile-configured.json"
      jq -e '
        all(.primaryAlbumTypes[]; .allowed) and
        all(.secondaryAlbumTypes[]; .allowed) and
        ([.releaseStatuses[] | select(.allowed) | .releaseStatus.name] == ["Official"])
      ' "$runtime_dir/metadata-profile-configured.json" > /dev/null

      api_get rootfolder > "$runtime_dir/root-folders.json"
      root_folder_id=$(jq -r \
        '[.[] | select((.path | rtrimstr("/")) == "/mnt/music")][0].id // empty' \
        "$runtime_dir/root-folders.json")
      if [[ -z "$root_folder_id" ]]; then
        jq -n \
          --arg path /mnt/music \
          --argjson qualityProfileId "$quality_profile_id" \
          --argjson metadataProfileId "$metadata_profile_id" \
          '{
            name: "Music",
            path: $path,
            defaultMetadataProfileId: $metadataProfileId,
            defaultQualityProfileId: $qualityProfileId,
            defaultMonitorOption: "none",
            defaultNewItemMonitorOption: "none",
            defaultTags: []
          }' > "$runtime_dir/root-folder-create.json"
        api_write POST rootfolder "$runtime_dir/root-folder-create.json" > /dev/null
      fi

      api_get rootfolder > "$runtime_dir/root-folders-configured.json"
      root_folder_id=$(jq -er \
        '[.[] | select((.path | rtrimstr("/")) == "/mnt/music")][0].id' \
        "$runtime_dir/root-folders-configured.json")
      api_get "rootfolder/$root_folder_id" > "$runtime_dir/root-folder.json"
      jq --argjson qualityProfileId "$quality_profile_id" \
        --argjson metadataProfileId "$metadata_profile_id" '
        .defaultMonitorOption = "none" |
        .defaultNewItemMonitorOption = "none" |
        .defaultQualityProfileId = $qualityProfileId |
        .defaultMetadataProfileId = $metadataProfileId
      ' "$runtime_dir/root-folder.json" > "$runtime_dir/root-folder-update.json"
      api_write PUT "rootfolder/$root_folder_id" \
        "$runtime_dir/root-folder-update.json" > /dev/null

      api_get artist > "$runtime_dir/artists-before-profile-update.json"
      library_artist_ids=$(jq -c '
        [
          .[] |
          select(.path == "/mnt/music" or (.path | startswith("/mnt/music/"))) |
          .id
        ]
      ' "$runtime_dir/artists-before-profile-update.json")
      managed_artist_ids=$(jq -c \
        --argjson qualityProfileId "$quality_profile_id" \
        --argjson metadataProfileId "$metadata_profile_id" '
        [
          .[] |
          select(.path == "/mnt/music" or (.path | startswith("/mnt/music/"))) |
          select(
            .qualityProfileId != $qualityProfileId or
            .metadataProfileId != $metadataProfileId or
            .monitored != false or
            ((.monitorNewItems // "") | ascii_downcase) != "none"
          ) |
          .id
        ]
      ' "$runtime_dir/artists-before-profile-update.json")
      managed_artist_count=$(jq -r length <<< "$managed_artist_ids")
      catalog_refresh_complete=0
      if [[ -e "$catalog_refresh_marker" && ! -f "$catalog_refresh_marker" ]]; then
        echo "Catalog refresh marker is not a regular file: $catalog_refresh_marker" >&2
        exit 1
      fi
      if [[ -f "$catalog_refresh_marker" ]] && \
        [[ "$(< "$catalog_refresh_marker")" == "$catalog_refresh_version" ]]
      then
        catalog_refresh_complete=1
      fi
      if ((managed_artist_count > 0)); then
        printf 'pending\n' > "$catalog_refresh_marker"
        chmod 0600 "$catalog_refresh_marker"
        catalog_refresh_complete=0
        jq -n \
          --argjson artistIds "$managed_artist_ids" \
          --argjson qualityProfileId "$quality_profile_id" \
          --argjson metadataProfileId "$metadata_profile_id" \
          '{
            artistIds: $artistIds,
            monitored: false,
            monitorNewItems: "none",
            qualityProfileId: $qualityProfileId,
            metadataProfileId: $metadataProfileId
          }' > "$runtime_dir/artist-profile-update.json"
        api_write PUT artist/editor "$runtime_dir/artist-profile-update.json" > /dev/null
      fi

      unmonitor_library_albums() {
        local monitored_album_ids
        local monitored_album_count

        api_get album > "$runtime_dir/library-albums.json"
        monitored_album_ids=$(jq -c --argjson artistIds "$library_artist_ids" '
          [
            .[] |
            select(.artistId as $artistId | $artistIds | index($artistId)) |
            select(.monitored) |
            .id
          ]
        ' "$runtime_dir/library-albums.json")
        monitored_album_count=$(jq -r length <<< "$monitored_album_ids")
        if ((monitored_album_count > 0)); then
          jq -n \
            --argjson albumIds "$monitored_album_ids" \
            '{albumIds: $albumIds, monitored: false}' \
            > "$runtime_dir/unmonitor-albums.json"
          api_write PUT album/monitor "$runtime_dir/unmonitor-albums.json" > /dev/null
        fi
      }

      unmonitor_library_albums

      if ((catalog_refresh_complete == 0)); then
        library_artist_count=$(jq -r length <<< "$library_artist_ids")
        if ((library_artist_count > 0)); then
          jq -n \
            --argjson artistIds "$library_artist_ids" \
            '{name: "RefreshArtist", artistIds: $artistIds}' \
            > "$runtime_dir/refresh-artists-command.json"
          run_command "$runtime_dir/refresh-artists-command.json" \
            "refresh artists after broadening the official release catalog"
        fi
        printf '%s\n' "$catalog_refresh_version" \
          > "$runtime_dir/catalog-refresh-complete"
        install -m 0600 "$runtime_dir/catalog-refresh-complete" \
          "$catalog_refresh_marker"
      fi

      unmonitor_library_albums

      api_get artist > "$runtime_dir/artists-after-profile-update.json"
      jq -e \
        --argjson qualityProfileId "$quality_profile_id" \
        --argjson metadataProfileId "$metadata_profile_id" '
        all(
          .[] | select(.path == "/mnt/music" or (.path | startswith("/mnt/music/")));
          .qualityProfileId == $qualityProfileId and
          .metadataProfileId == $metadataProfileId and
          .monitored == false and
          ((.monitorNewItems // "") | ascii_downcase) == "none"
        )
      ' "$runtime_dir/artists-after-profile-update.json" > /dev/null
      api_get album > "$runtime_dir/albums-after-profile-update.json"
      jq -e --argjson artistIds "$library_artist_ids" '
        all(
          .[] | select(.artistId as $artistId | $artistIds | index($artistId));
          .monitored == false
        )
      ' "$runtime_dir/albums-after-profile-update.json" > /dev/null

      api_get config/naming > "$runtime_dir/naming-config.json"
      naming_config_id=$(jq -er .id "$runtime_dir/naming-config.json")
      jq '
        .renameTracks = true |
        .replaceIllegalCharacters = false |
        .standardTrackFormat = "{Album Title}/{track:00}. {Track Title}" |
        .multiDiscTrackFormat = "{Album Title}/{medium:00}-{track:00}. {Track Title}" |
        .artistFolderFormat = "{Artist Name}"
      ' "$runtime_dir/naming-config.json" > "$runtime_dir/naming-config-update.json"
      api_write PUT "config/naming/$naming_config_id" \
        "$runtime_dir/naming-config-update.json" > /dev/null

      api_get config/metadataprovider > "$runtime_dir/metadata-provider-config.json"
      metadata_provider_config_id=$(jq -er .id "$runtime_dir/metadata-provider-config.json")
      jq '
        .writeAudioTags = "newFiles" |
        .scrubAudioTags = false |
        .embedCoverArt = false
      ' "$runtime_dir/metadata-provider-config.json" \
        > "$runtime_dir/metadata-provider-config-update.json"
      api_write PUT "config/metadataprovider/$metadata_provider_config_id" \
        "$runtime_dir/metadata-provider-config-update.json" > /dev/null

      migrated_files=0
      if [[ -e "$punctuation_migration_marker" && ! -f "$punctuation_migration_marker" ]]; then
        echo "Punctuation migration marker is not a regular file: $punctuation_migration_marker" >&2
        exit 1
      fi

      if [[ ! -f "$punctuation_migration_marker" ]]; then
        migration_targets='[
          {"artist":"2hollis","albums":["boy"],"expectedFiles":13},
          {"artist":"shteppi","albums":["20.","a little bit.","are you lonely?"],"expectedFiles":44}
        ]'
        api_get artist > "$runtime_dir/artists.json"
        migration_backup_created=0

      while IFS= read -r migration_target; do
        artist_name=$(jq -r .artist <<< "$migration_target")
        wanted_albums=$(jq -c .albums <<< "$migration_target")
        expected_files=$(jq -r .expectedFiles <<< "$migration_target")
        expected_album_count=$(jq -r '.albums | length' <<< "$migration_target")
        artist_matches=$(jq -c --arg artistName "$artist_name" '
          [
            .[] |
            select((.artistName | ascii_downcase) == ($artistName | ascii_downcase)) |
            select(.path | startswith("/mnt/music/"))
          ]
        ' "$runtime_dir/artists.json")
        artist_match_count=$(jq -r length <<< "$artist_matches")
        if [[ "$artist_match_count" != 1 ]]; then
          echo "Expected one /mnt/music artist named $artist_name, found $artist_match_count" >&2
          exit 1
        fi
        artist_id=$(jq -er '.[0].id' <<< "$artist_matches")
        artist_path=$(jq -er '.[0].path' <<< "$artist_matches")

        api_get "album?artistId=$artist_id" > "$runtime_dir/migration-albums.json"
        album_ids=$(jq -c --argjson wanted "$wanted_albums" '
          [
            .[] |
            select(
              (.title | ascii_downcase) as $title |
              ($wanted | map(ascii_downcase) | index($title)) != null
            ) |
            .id
          ]
        ' "$runtime_dir/migration-albums.json")
        actual_album_count=$(jq -r length <<< "$album_ids")
        if [[ "$actual_album_count" != "$expected_album_count" ]]; then
          echo "Expected $expected_album_count migration albums for $artist_name, found $actual_album_count" >&2
          exit 1
        fi

        api_get "rename?artistId=$artist_id" > "$runtime_dir/rename-preview-all.json"
        jq --arg artistPath "$artist_path" --argjson albumIds "$album_ids" '
          [
            .[] |
            select(.albumId as $albumId | $albumIds | index($albumId)) |
            select(.existingPath | startswith($artistPath + "/"))
          ]
        ' "$runtime_dir/rename-preview-all.json" > "$runtime_dir/rename-preview.json"
        rename_count=$(jq -r length "$runtime_dir/rename-preview.json")

        if ((rename_count > expected_files)); then
          echo "Refusing to rename $rename_count files for $artist_name; expected at most $expected_files" >&2
          exit 1
        fi

        if ((rename_count > 0)); then
          if ((migration_backup_created == 0)); then
            api_get 'queue?page=1&pageSize=100&includeUnknownArtistItems=true' \
              > "$runtime_dir/migration-queue.json"
            if ! jq -e '.totalRecords == 0' "$runtime_dir/migration-queue.json" > /dev/null; then
              echo "Refusing to organize files while Lidarr's queue is not empty" >&2
              exit 1
            fi

            jq -n '{name: "Backup"}' > "$runtime_dir/backup-command.json"
            run_command "$runtime_dir/backup-command.json" "back up Lidarr before organizing files"
            migration_backup_created=1
          fi

          jq -e --arg artistPath "$artist_path" --argjson wantedAlbums "$wanted_albums" '
            all(.[];
              (.newPath | startswith($artistPath + "/")) and
              (.newPath != .existingPath) and
              (
                (.newPath | ltrimstr($artistPath + "/") | split("/")) as $components |
                ($components | length) == 2 and
                ($wantedAlbums | index($components[0])) != null and
                ($components[1] | test("^[0-9]{2}\\. .+\\.[^./]+$"))
              )
            )
          ' "$runtime_dir/rename-preview.json" > /dev/null
          jq -e '
            ([.[].newPath] | length) == ([.[].newPath] | unique | length)
          ' "$runtime_dir/rename-preview.json" > /dev/null

          : > "$runtime_dir/rename-hashes.ndjson"
          while IFS=$'\t' read -r track_file_id existing_path new_path; do
            if [[ ! -f "$existing_path" ]]; then
              echo "Tracked rename source is not a file: $existing_path" >&2
              exit 1
            fi
            if [[ -e "$new_path" ]]; then
              echo "Refusing to overwrite rename destination: $new_path" >&2
              exit 1
            fi

            audio_hash_line=$(sha256sum -- "$existing_path")
            audio_hash="''${audio_hash_line%% *}"
            existing_lyric="''${existing_path%.*}.lrc"
            new_lyric="''${new_path%.*}.lrc"
            if [[ -e "$new_lyric" ]]; then
              echo "Refusing to overwrite lyric destination: $new_lyric" >&2
              exit 1
            fi
            lyric_hash=""
            if [[ -f "$existing_lyric" ]]; then
              lyric_hash_line=$(sha256sum -- "$existing_lyric")
              lyric_hash="''${lyric_hash_line%% *}"
            fi

            jq -nc \
              --argjson trackFileId "$track_file_id" \
              --arg existingPath "$existing_path" \
              --arg newPath "$new_path" \
              --arg existingLyricPath "$existing_lyric" \
              --arg newLyricPath "$new_lyric" \
              --arg audioHash "$audio_hash" \
              --arg lyricHash "$lyric_hash" \
              '{
                trackFileId: $trackFileId,
                existingPath: $existingPath,
                newPath: $newPath,
                existingLyricPath: $existingLyricPath,
                newLyricPath: $newLyricPath,
                audioHash: $audioHash,
                lyricHash: $lyricHash
              }' >> "$runtime_dir/rename-hashes.ndjson"
          done < <(jq -r '.[] | [.trackFileId, .existingPath, .newPath] | @tsv' \
            "$runtime_dir/rename-preview.json")
          jq -s -e '
            (map(.newLyricPath) | length) == (map(.newLyricPath) | unique | length)
          ' "$runtime_dir/rename-hashes.ndjson" > /dev/null

          rename_file_ids=$(jq -c '[.[].trackFileId]' "$runtime_dir/rename-preview.json")
          jq -n \
            --argjson artistId "$artist_id" \
            --argjson files "$rename_file_ids" \
            '{name: "RenameFiles", artistId: $artistId, files: $files}' \
            > "$runtime_dir/rename-command.json"
          run_command "$runtime_dir/rename-command.json" "organize $artist_name"

          while IFS= read -r rename_manifest; do
            existing_path=$(jq -r .existingPath <<< "$rename_manifest")
            new_path=$(jq -r .newPath <<< "$rename_manifest")
            existing_lyric=$(jq -r .existingLyricPath <<< "$rename_manifest")
            new_lyric=$(jq -r .newLyricPath <<< "$rename_manifest")
            expected_audio_hash=$(jq -r .audioHash <<< "$rename_manifest")
            expected_lyric_hash=$(jq -r .lyricHash <<< "$rename_manifest")
            if [[ -e "$existing_path" || ! -e "$new_path" ]]; then
              echo "Lidarr did not complete rename: $existing_path -> $new_path" >&2
              exit 1
            fi
            if [[ -e "$existing_lyric" && -e "$new_lyric" ]]; then
              echo "Refusing to overwrite lyric destination: $new_lyric" >&2
              exit 1
            fi
            if [[ -e "$existing_lyric" ]]; then
              mv -- "$existing_lyric" "$new_lyric"
            fi

            audio_hash_line=$(sha256sum -- "$new_path")
            audio_hash="''${audio_hash_line%% *}"
            if [[ "$audio_hash" != "$expected_audio_hash" ]]; then
              echo "Audio content changed while renaming: $new_path" >&2
              exit 1
            fi

            if [[ -n "$expected_lyric_hash" ]]; then
              if [[ ! -f "$new_lyric" ]]; then
                echo "Lyric sidecar was not moved: $new_lyric" >&2
                exit 1
              fi
              lyric_hash_line=$(sha256sum -- "$new_lyric")
              lyric_hash="''${lyric_hash_line%% *}"
              if [[ "$lyric_hash" != "$expected_lyric_hash" ]]; then
                echo "Lyric content changed while renaming: $new_lyric" >&2
                exit 1
              fi
            fi
          done < "$runtime_dir/rename-hashes.ndjson"

          ((migrated_files += rename_count))
        fi

        api_get "rename?artistId=$artist_id" > "$runtime_dir/rename-preview-after.json"
        jq --argjson albumIds "$album_ids" '
          [.[] | select(.albumId as $albumId | $albumIds | index($albumId))]
        ' "$runtime_dir/rename-preview-after.json" \
          > "$runtime_dir/rename-preview-after-targets.json"
        if ! jq -e 'length == 0' \
          "$runtime_dir/rename-preview-after-targets.json" > /dev/null
        then
          echo "Lidarr still proposes renames for selected albums by $artist_name" >&2
          exit 1
        fi
        done < <(jq -c '.[]' <<< "$migration_targets")
        install -m 0600 /dev/null "$punctuation_migration_marker"
      fi

      echo "Configured Lidarr's slskd and Apple Music/gamdl backends, automatic and interactive search, lossless-first AAC fallback, official-release catalog, naming, tags, protocols, and music root"
      echo "Organized $migrated_files selected track files without changing audio or lyric content"
    '';
  };
in
  delib.module {
    name = "polaris";

    nixos.ifEnabled = {
      sops = {
        secrets = {
          slskd_api_key.restartUnits = [
            "lidarr-gamdl-bridge.service"
            "lidarr-slskd-bootstrap.service"
          ];
          slskd_env = {};
        };

        templates."slskd.yml" = {
          owner = "slskd";
          group = "media";
          mode = "0400";
          restartUnits = ["slskd.service"];
          content = ''
            directories:
              downloads: ${slskdDownloadDir}
            remote_file_management: true
            shares:
              directories:
                - /mnt/music
            feature:
              swagger: true
            transfers:
              download:
                slots: 5
            web:
              ip_address: 127.0.0.1
              port: 5030
              https:
                disabled: true
              authentication:
                api_keys:
                  lidarr:
                    key: ${config.sops.placeholder.slskd_api_key}
                    role: readwrite
                    cidr: 127.0.0.1/32
          '';
        };
      };

      services = {
        jellyfin = {
          enable = true;
          openFirewall = false;
          dataDir = "/mnt/jellyfin";
          package = pkgs.local.jellyfin;
        };

        lidarr = {
          enable = true;
          package = pkgs.local.lidarr;
          dataDir = lidarrDataDir;
          group = "media";
          openFirewall = false;
          settings = {
            auth = {
              method = "Forms";
              required = "Enabled";
            };
            log.analyticsEnabled = false;
            server = {
              # IPv4-only: the firewall admits only the LAN subnet and tailscale0.
              bindaddress = "0.0.0.0";
              port = 8686;
            };
            update = {
              automatically = false;
              branch = "develop";
              mechanism = "external";
            };
          };
        };

        samba = {
          enable = true;
          openFirewall = false;
          nmbd.enable = false;

          settings = {
            music = {
              path = "/mnt/music";
              browseable = "yes";
              "read only" = "no";
              "guest ok" = "no";
              "create mask" = "0664";
              "directory mask" = "0775";
              "valid users" = "marshall";
            };
          };
        };

        samba-wsdd.enable = false;

        slskd = {
          enable = true;
          openFirewall = true;
          package = pkgs.local.slskd;
          user = "slskd";
          group = "media";
          domain = null;
          environmentFile = config.sops.secrets.slskd_env.path;

          settings = {
            directories.downloads = slskdDownloadDir;
            feature.swagger = true;
            remote_file_management = true;
            shares.directories = ["/mnt/music"];
            transfers.download.slots = 5;
            web = {
              ip_address = "127.0.0.1";
              https.disabled = true;
            };
          };
        };
      };

      systemd = {
        services = {
          jellyfin = {
            after = ["mnt.mount"];
            requires = ["mnt.mount"];
          };

          samba-smbd = {
            after = ["mnt.mount"];
            requires = ["mnt.mount"];
          };

          lidarr-gamdl-bridge = {
            description = "Lidarr Apple Music download bridge for gamdl";
            after = ["mnt.mount" "network-online.target"];
            requires = ["mnt.mount"];
            wants = ["network-online.target"];
            wantedBy = ["multi-user.target"];
            unitConfig = {
              StartLimitBurst = 5;
              StartLimitIntervalSec = 300;
            };
            serviceConfig = {
              Type = "simple";
              ExecStart = pkgs.lib.escapeShellArgs [
                (pkgs.lib.getExe pkgs.local.lidarr-gamdl-bridge)
                "--host"
                "127.0.0.1"
                "--port"
                (toString gamdlBridgePort)
                "--api-key-file"
                "%d/api-key"
                "--state-dir"
                "/var/lib/lidarr-gamdl-bridge"
                "--download-dir"
                gamdlDownloadDir
                "--wrapper-url"
                "http://127.0.0.1:8080"
                "--decrypt-host"
                "127.0.0.1"
                "--decrypt-port"
                "10020"
                "--workers"
                "3"
              ];
              User = "lidarr-gamdl";
              Group = "media";
              Restart = "on-failure";
              RestartSec = "5s";
              StateDirectory = "lidarr-gamdl-bridge";
              StateDirectoryMode = "0750";
              CacheDirectory = "lidarr-gamdl-bridge";
              CacheDirectoryMode = "0750";
              LoadCredential = [
                "api-key:${config.sops.secrets.slskd_api_key.path}"
              ];
              Environment = [
                "PYTHONUNBUFFERED=1"
                "UV_CACHE_DIR=/var/cache/lidarr-gamdl-bridge/uv"
              ];
              NoNewPrivileges = true;
              PrivateDevices = true;
              PrivateTmp = true;
              ProtectClock = true;
              ProtectControlGroups = true;
              ProtectHome = true;
              ProtectHostname = true;
              ProtectKernelLogs = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectSystem = "strict";
              ReadWritePaths = [gamdlDownloadDir];
              RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
              RestrictRealtime = true;
              UMask = "0002";
            };
          };

          lidarr = {
            after = ["mnt.mount" "slskd.service" "lidarr-gamdl-bridge.service"];
            requires = ["mnt.mount"];
            wants = ["slskd.service" "lidarr-gamdl-bridge.service"];
            preStart = ''
              ${pkgs.coreutils}/bin/install -d -m 0750 ${lidarrPluginDir}
              ${pkgs.rsync}/bin/rsync -rlt --delete --chmod=D0750,F0640 \
                ${pkgs.local.lidarr-plugin-slskd}/ ${lidarrPluginDir}/
            '';
            serviceConfig = {
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectHome = true;
              ProtectSystem = "strict";
              ReadWritePaths = [
                "/var/lib/lidarr"
                "/mnt/music"
                gamdlDownloadDir
                slskdDownloadDir
              ];
              UMask = "0002";
            };
          };

          lidarr-slskd-bootstrap = {
            description = "Configure Lidarr's slskd and gamdl backends";
            after = [
              "lidarr.service"
              "lidarr-gamdl-bridge.service"
              "slskd.service"
            ];
            requires = ["lidarr-gamdl-bridge.service" "slskd.service"];
            wantedBy = ["lidarr.service"];
            partOf = ["lidarr.service"];
            unitConfig = {
              StartLimitBurst = 3;
              StartLimitIntervalSec = 300;
            };
            serviceConfig = {
              # Type=exec releases the NixOS activation transaction as soon as the
              # bootstrap has been launched; the long catalog refresh continues in
              # the service and retains normal failure/restart reporting.
              Type = "exec";
              ExecStart = "${lidarrSlskdBootstrap}/bin/lidarr-slskd-bootstrap";
              Restart = "on-failure";
              RestartSec = "15s";
              RuntimeDirectory = "lidarr-slskd-bootstrap";
              RuntimeDirectoryMode = "0700";
              # Readiness can take 3 minutes and the guarded first-run migration can
              # issue four commands with a 15-minute poll window apiece.
              RuntimeMaxSec = "75min";
              TimeoutStartSec = "30s";
              UMask = "0077";
            };
          };

          slskd = {
            after = ["mnt.mount"];
            requires = ["mnt.mount"];

            serviceConfig = {
              ExecStart = pkgs.lib.mkForce "${pkgs.local.slskd}/bin/slskd --app-dir /var/lib/slskd --config ${config.sops.templates."slskd.yml".path}";
              RuntimeDirectory = "slskd";
              UMask = "0002";
            };
          };
        };

        tmpfiles.rules = [
          "z /mnt 0755 root root - -"
          "d /mnt/downloads 2775 root media - -"
          "d ${gamdlDownloadDir} 2775 lidarr-gamdl media - -"
          "a ${gamdlDownloadDir} - - - - g:media:rwx,d:g:media:rwx"
          "d ${slskdDownloadDir} 2775 slskd media - -"
          "a ${slskdDownloadDir} - - - - g:media:rwx,d:g:media:rwx"
          "d /mnt/music 2775 slskd media - -"
          "a /mnt/music - - - - g:media:rwx,d:g:media:rwx"
        ];
      };

      users = {
        groups.media = {};
        users.lidarr-gamdl = {
          isSystemUser = true;
          group = "media";
          description = "Lidarr gamdl bridge";
        };
        users.jellyfin.extraGroups = ["media"];
      };
    };
  }
