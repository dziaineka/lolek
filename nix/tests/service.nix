{
  pkgs,
  module,
  package,
  telegym,
}:

let
  serviceUser = "lolek";
  serviceGroup = serviceUser;
  serviceName = "lolek";
  serviceUnit = "${serviceName}.service";
  stateDir = "/var/lib/${serviceUser}";
  downloadDir = "${stateDir}/downloads";
  readyDirName = "ready_to_telegram";
  mediaManifestName = "media_manifest.json";

  mediaOriginName = "lolek-media-origin";
  mediaOriginUnit = "${mediaOriginName}.service";
  testHost = "127.0.0.1";
  mediaOriginPort = 8081;
  mediaOriginBaseUrl = "http://${testHost}:${toString mediaOriginPort}";
  telegymPort = 5678;
  telegymBaseUrl = "http://${testHost}:${toString telegymPort}";
  telegymUnit = "telegym-mock.service";
  fakeToken = "dummy-token";
  uploadDir = "/tmp/lolek-service-uploads";
  passthroughUploadFile = "${uploadDir}/passthrough.bin";
  compressedUploadFile = "${uploadDir}/compressed.bin";
  metricsPort = 9568;

  passthroughMediaPath = "/passthrough.mp4";
  passthroughMediaUrl = "${mediaOriginBaseUrl}${passthroughMediaPath}";
  passthroughMediaWidth = 160;
  passthroughMediaHeight = 90;
  passthroughMediaDuration = 1;
  passthroughSourceCaption = "Cached source caption";
  passthroughSourceTitle = "Passthrough Cached Title";
  legacyMediaPath = "/legacy-cached.mp4";
  legacyMediaUrl = "${mediaOriginBaseUrl}${legacyMediaPath}";
  legacyVideoFileId = "fake-legacy-video-file-id";
  compressedMediaPath = "/compressed.mp4";
  compressedMediaUrl = "${mediaOriginBaseUrl}${compressedMediaPath}";
  compressedMediaWidth = 640;
  compressedMediaHeight = 360;
  compressedMediaDuration = 5;
  maxFileSizeToSendToTelegram = 45000000;
  maxGalleryMedia = 37;
  maxVideoSizeToSendToTelegram = 40000000;
  maxAudioSizeToSendToTelegram = 5000000;
  maxFileSizeToCompress = 100000000;
  maxDurationToCompress = 300;

  passthroughMediaFile =
    pkgs.runCommand "lolek-test-passthrough-media.mp4" { nativeBuildInputs = [ pkgs.ffmpeg ]; }
      ''
        ffmpeg \
          -f lavfi -i testsrc=size=${toString passthroughMediaWidth}x${toString passthroughMediaHeight}:rate=10 \
          -f lavfi -i anullsrc=channel_layout=mono:sample_rate=44100 \
          -t ${toString passthroughMediaDuration} \
          -pix_fmt yuv420p \
          -c:v libx264 \
          -preset ultrafast \
          -c:a aac \
          -movflags +faststart \
          "$out"
      '';

  compressedMediaFile =
    pkgs.runCommand "lolek-test-compressed-media.mp4" { nativeBuildInputs = [ pkgs.ffmpeg ]; }
      ''
        ffmpeg \
          -f lavfi -i testsrc2=size=${toString compressedMediaWidth}x${toString compressedMediaHeight}:rate=30 \
          -f lavfi -i anullsrc=channel_layout=mono:sample_rate=44100 \
          -t ${toString compressedMediaDuration} \
          -pix_fmt yuv420p \
          -c:v libx264 \
          -preset ultrafast \
          -b:v 100M \
          -minrate 100M \
          -maxrate 100M \
          -bufsize 200M \
          -x264-params nal-hrd=cbr:force-cfr=1 \
          -c:a aac \
          -movflags +faststart \
          "$out"
      '';
in
pkgs.testers.nixosTest {
  name = "lolek-service";

  containers.machine =
    { ... }:
    {
      imports = [
        module
        (import ./telegym-service.nix {
          package = telegym;
          port = telegymPort;
        })
      ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.gnugrep
        pkgs.jq
      ];

      services.lolek = {
        enable = true;
        inherit package;
        user = serviceUser;
        group = serviceGroup;
        inherit stateDir downloadDir;
        botTokenFile = pkgs.writeText "lolek-test-token" fakeToken;
        allowedUrlPatterns = [ testHost ];
        maxDownloadDirSize = 0;
        maxConcurrentDownloads = 2;
        maxConcurrentDownloadsPerChat = 1;
        maxDownloadTries = 1;
        startDownloadPause = 10;
        maxDownloadPause = 10;
        postSourceCaption = true;
        postRequesterCaption = true;
        inherit maxGalleryMedia;
        metrics = {
          enable = true;
          port = metricsPort;
        };
        inherit
          maxFileSizeToSendToTelegram
          maxVideoSizeToSendToTelegram
          maxAudioSizeToSendToTelegram
          maxFileSizeToCompress
          maxDurationToCompress
          ;
        environment = {
          LOLEK_TELEGRAM_BASE_URL = telegymBaseUrl;
        };
      };

      systemd.services.${mediaOriginName} = {
        description = "Media origin for Lolek service integration test";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LOLEK_MEDIA_ORIGIN_HOST = testHost;
          LOLEK_MEDIA_ORIGIN_PORT = toString mediaOriginPort;
          LOLEK_MEDIA_ORIGIN_PASSTHROUGH_PATH = passthroughMediaPath;
          LOLEK_MEDIA_ORIGIN_PASSTHROUGH_FILE = toString passthroughMediaFile;
          LOLEK_MEDIA_ORIGIN_LEGACY_PATH = legacyMediaPath;
          LOLEK_MEDIA_ORIGIN_LEGACY_FILE = toString passthroughMediaFile;
          LOLEK_MEDIA_ORIGIN_COMPRESSED_PATH = compressedMediaPath;
          LOLEK_MEDIA_ORIGIN_COMPRESSED_FILE = toString compressedMediaFile;
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./service-media-origin.py}";
          Restart = "on-failure";
        };
      };

      systemd.services.${serviceName}.wantedBy = pkgs.lib.mkForce [ ];
    };

  testScript = ''
    import base64
    import json
    import shlex

    def shell_quote(value):
        return shlex.quote(value)

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("${mediaOriginUnit}")
    machine.wait_for_unit("${telegymUnit}")

    ready_dir_name = "${readyDirName}"
    media_manifest_name = "${mediaManifestName}"
    service_user = "${serviceUser}"
    service_group = "${serviceGroup}"
    download_dir = "${downloadDir}"
    telegym_base_url = "${telegymBaseUrl}"
    fake_token = "${fakeToken}"
    messages_url = "%s/debug/messages/%s?chat_id=1234" % (
        telegym_base_url,
        fake_token,
    )
    passthrough_upload_file = "${passthroughUploadFile}"
    compressed_upload_file = "${compressedUploadFile}"
    max_file_size_to_send_to_telegram = ${toString maxFileSizeToSendToTelegram}
    max_gallery_media = ${toString maxGalleryMedia}
    passthrough_media_file = "${passthroughMediaFile}"
    passthrough_media_url = "${passthroughMediaUrl}"
    passthrough_source_caption = "${passthroughSourceCaption}"
    passthrough_source_title = "${passthroughSourceTitle}"
    legacy_media_url = "${legacyMediaUrl}"
    legacy_video_file_id = "${legacyVideoFileId}"
    metrics_url = "http://127.0.0.1:${toString metricsPort}/metrics"
    metrics_file = "/tmp/lolek-metrics.prom"
    compressed_media_file = "${compressedMediaFile}"
    compressed_media_url = "${compressedMediaUrl}"
    passthrough_folder_name = base64.b64encode(passthrough_media_url.encode()).decode().rstrip("=")
    passthrough_cache_dir = "%s/%s" % (download_dir, passthrough_folder_name)
    passthrough_metadata_file = "%s/source_metadata.json" % passthrough_cache_dir
    legacy_folder_name = base64.b64encode(legacy_media_url.encode()).decode().rstrip("=")
    legacy_cache_dir = "%s/%s" % (download_dir, legacy_folder_name)
    legacy_ready_dir = "%s/%s" % (legacy_cache_dir, ready_dir_name)
    legacy_cache_file = "%s/%s.mp4" % (legacy_ready_dir, legacy_video_file_id)
    compressed_folder_name = base64.b64encode(compressed_media_url.encode()).decode().rstrip("=")
    compressed_cache_dir = "%s/%s" % (download_dir, compressed_folder_name)

    def inject(url):
        payload = json.dumps(
            {
                "token": fake_token,
                "chat_id": 1234,
                "username": "test_user",
                "first_name": "Test User",
                "text": url,
            },
            separators=(",", ":"),
        )
        machine.succeed(
            "curl -fsS -H 'Content-Type: application/json' --data %s "
            "%s/debug/inject/update | "
            "jq -e '.ok and .delivery_method == \"polling\"' >/dev/null"
            % (shell_quote(payload), telegym_base_url)
        )

    def video_messages():
        response = json.loads(
            machine.succeed("curl -fsS %s" % shell_quote(messages_url))
        )
        return [message for message in response["messages"] if message.get("video")]

    def wait_for_video_count(expected):
        machine.wait_until_succeeds(
            "curl -fsS %s | "
            "jq -e '[.messages[] | select(.video != null)] | length == %d' "
            ">/dev/null" % (shell_quote(messages_url), expected)
        )
        messages = video_messages()
        assert len(messages) == expected, messages
        return messages

    def wait_for_idle():
        machine.wait_until_succeeds(
            "curl -fsS %s | grep -F 'lolek_processing_active 0' >/dev/null"
            % metrics_url
        )

    machine.succeed(
        "systemctl show ${serviceUnit} --property=Environment --value | "
        "grep -F 'LOLEK_MAX_GALLERY_MEDIA=%s'" % max_gallery_media
    )

    # The module should create the service user, group, and writable download directory.
    machine.succeed("getent passwd %s" % service_user)
    machine.succeed("getent group %s" % service_group)
    machine.succeed("test -d %s" % download_dir)
    machine.succeed("test $(stat -c %%U %s) = %s" % (download_dir, service_user))
    machine.succeed("test $(stat -c %%G %s) = %s" % (download_dir, service_group))
    machine.succeed("su -s /bin/sh %s -c 'test -w %s'" % (service_user, download_dir))

    machine.wait_until_succeeds("curl -fsS %s >/dev/null" % passthrough_media_url)
    machine.wait_until_succeeds("curl -fsS %s >/dev/null" % compressed_media_url)
    machine.wait_until_succeeds(
        "curl -fsS %s/health | jq -e '.status == \"ok\"' >/dev/null"
        % telegym_base_url
    )

    # A cached source title should be used as the multipart filename for fresh uploads.
    passthrough_metadata = json.dumps(
        {
            "caption": passthrough_source_caption,
            "title": passthrough_source_title,
        },
        separators=(",", ":"),
    )
    machine.succeed(
        "install -d -o %s -g %s -m 0750 %s"
        % (service_user, service_group, shell_quote(passthrough_cache_dir))
    )
    machine.succeed(
        "printf %s > %s"
        % (shell_quote(passthrough_metadata), shell_quote(passthrough_metadata_file))
    )
    machine.succeed(
        "chown %s:%s %s"
        % (service_user, service_group, shell_quote(passthrough_metadata_file))
    )

    # Simulate a valid single-file cache left by a pre-manifest Lolek release.
    machine.succeed(
        "install -d -o %s -g %s -m 0750 %s"
        % (service_user, service_group, shell_quote(legacy_ready_dir))
    )
    machine.succeed(
        "install -o %s -g %s -m 0640 %s %s"
        % (
            service_user,
            service_group,
            shell_quote(passthrough_media_file),
            shell_quote(legacy_cache_file),
        )
    )

    machine.succeed("systemctl start ${serviceUnit}")
    machine.wait_for_unit("${serviceUnit}")
    machine.wait_until_succeeds(
        "curl -fsS %s/debug/bots | "
        "jq -e --arg token %s '.bots | any(.token_full == $token)' >/dev/null"
        % (telegym_base_url, shell_quote(fake_token))
    )
    machine.succeed("mkdir -p %s" % shell_quote("${uploadDir}"))

    # A small MP4 should be uploaded without ffmpeg compression.
    inject(passthrough_media_url)
    messages = wait_for_video_count(1)
    passthrough_message = messages[0]
    passthrough_video = passthrough_message["video"]
    passthrough_video_file_id = passthrough_video["file_id"]
    assert passthrough_video["file_name"] == "%s.mp4" % passthrough_source_title
    assert passthrough_source_caption in passthrough_message["caption"]
    machine.succeed(
        "curl -fsS %s/debug/files/%s -o %s"
        % (
            telegym_base_url,
            passthrough_video_file_id,
            shell_quote(passthrough_upload_file),
        )
    )
    machine.succeed("test -s %s" % shell_quote(passthrough_upload_file))
    machine.succeed("grep -aq 'ftyp' %s" % shell_quote(passthrough_upload_file))
    machine.succeed(
        "curl -fsS %s/debug/files | jq -e '.count == 1' >/dev/null"
        % telegym_base_url
    )
    wait_for_idle()

    # The same URL should reuse the cached Telegram file ID without another upload.
    inject(passthrough_media_url)
    messages = wait_for_video_count(2)
    assert messages[0]["video"]["file_id"] == passthrough_video_file_id, messages[0]
    machine.succeed(
        "curl -fsS %s/debug/files | jq -e '.count == 1' >/dev/null"
        % telegym_base_url
    )
    wait_for_idle()

    # A pre-manifest cache should be sent without downloading unavailable media.
    inject(legacy_media_url)
    messages = wait_for_video_count(3)
    assert messages[0]["video"]["file_id"] == legacy_video_file_id, messages[0]
    wait_for_idle()
    machine.succeed(
        "journalctl -u ${serviceUnit} --no-pager | "
        "grep -F %s | grep -F 'result=ok:ready_media:count=1'"
        % shell_quote("Finished download for url: %s;" % legacy_media_url)
    )
    machine.succeed("test -f %s" % shell_quote(legacy_cache_file))
    machine.succeed(
        "test ! -e %s"
        % shell_quote("%s/%s" % (legacy_ready_dir, media_manifest_name))
    )

    # Media larger than the Telegram send limit should go through compression.
    inject(compressed_media_url)
    messages = wait_for_video_count(4)
    compressed_video_file_id = messages[0]["video"]["file_id"]
    machine.succeed(
        "curl -fsS %s/debug/files/%s -o %s"
        % (
            telegym_base_url,
            compressed_video_file_id,
            shell_quote(compressed_upload_file),
        )
    )
    machine.succeed("test -s %s" % shell_quote(compressed_upload_file))
    machine.succeed("grep -aq 'ftyp' %s" % shell_quote(compressed_upload_file))
    machine.succeed(
        "curl -fsS %s/debug/files | jq -e '.count == 2' >/dev/null"
        % telegym_base_url
    )
    wait_for_idle()
    machine.succeed(
        "test $(journalctl -u ${serviceUnit} --no-pager | grep -c 'Compressed video with libx264') -eq 1"
    )

    # Both uploads should have Telegym's returned file IDs cached in manifests.
    passthrough_manifest_file = "%s/%s/%s" % (
        passthrough_cache_dir,
        ready_dir_name,
        media_manifest_name,
    )
    passthrough_manifest = json.loads(
        machine.succeed("cat %s" % shell_quote(passthrough_manifest_file))
    )
    assert passthrough_manifest == [
        {"ext": ".mp4", "file_id": passthrough_video_file_id}
    ], passthrough_manifest
    machine.succeed(
        "grep -aq %s %s"
        % (
            shell_quote('"caption":"%s"' % passthrough_source_caption),
            shell_quote(passthrough_metadata_file),
        )
    )
    machine.succeed(
        "grep -aq %s %s"
        % (
            shell_quote('"title":"%s"' % passthrough_source_title),
            shell_quote(passthrough_metadata_file),
        )
    )
    machine.succeed(
        "test $(stat -c %%s %s) -le %d"
        % (passthrough_media_file, max_file_size_to_send_to_telegram)
    )

    compressed_manifest_file = "%s/%s/%s" % (
        compressed_cache_dir,
        ready_dir_name,
        media_manifest_name,
    )
    compressed_manifest = json.loads(
        machine.succeed("cat %s" % shell_quote(compressed_manifest_file))
    )
    assert compressed_manifest == [
        {"ext": ".mp4", "file_id": compressed_video_file_id}
    ], compressed_manifest
    machine.succeed(
        "test $(stat -c %%s %s) -gt %d"
        % (compressed_media_file, max_file_size_to_send_to_telegram)
    )
    compressed_prepared_file = "%s/compressed.mp4" % compressed_cache_dir
    machine.succeed(
        "test $(stat -c %%s %s) -le %d"
        % (compressed_prepared_file, max_file_size_to_send_to_telegram)
    )

    # The optional Prometheus endpoint should expose metrics from the exercised service path.
    machine.succeed("curl -fsS %s > %s" % (metrics_url, metrics_file))
    machine.succeed(
        "grep -F 'lolek_messages_total{result=\"ok\"} 4' %s" % metrics_file
    )
    machine.succeed(
        "grep -F 'lolek_chat_rate_limiter_total{result=\"admitted\"} 4' %s"
        % metrics_file
    )
    machine.succeed(
        "grep -F 'lolek_cache_lookup_total{state=\"new_file\"} 2' %s" % metrics_file
    )
    machine.succeed(
        "grep -F 'lolek_cache_lookup_total{state=\"ready_to_telegram\"} 2' %s"
        % metrics_file
    )
    machine.succeed(
        "grep -F 'lolek_processing_stage_total{result=\"ok\",stage=\"telegram_send\"} 4' %s"
        % metrics_file
    )
    machine.succeed(
        "grep -F 'lolek_processing_stage_duration_seconds_count{result=\"ok\",stage=\"telegram_send\"} 4' %s"
        % metrics_file
    )
    machine.succeed("grep -F 'lolek_processing_active 0' %s" % metrics_file)

    # On-demand cleanup should remove new-format cache entries while leaving the service alive.
    machine.succeed("${package}/bin/lolek rpc 'Lolek.FileCleaner.cleanup_now()'")
    machine.succeed("test ! -e %s" % passthrough_cache_dir)
    machine.succeed("test ! -e %s" % compressed_cache_dir)
    machine.succeed("systemctl is-active --quiet ${serviceUnit}")
  '';
}
