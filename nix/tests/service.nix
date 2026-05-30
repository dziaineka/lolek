{
  pkgs,
  module,
  package,
}:

let
  serviceUser = "lolek";
  serviceGroup = serviceUser;
  serviceName = "lolek";
  serviceUnit = "${serviceName}.service";
  stateDir = "/var/lib/${serviceUser}";
  downloadDir = "${stateDir}/downloads";
  readyDirName = "ready_to_telegram";
  envFileName = "${serviceName}.env";

  fakeServicesName = "lolek-fake-services";
  fakeServicesUnit = "${fakeServicesName}.service";
  fakeHost = "127.0.0.1";
  fakePort = 8081;
  fakeToken = "dummy-token";
  fakeLogDir = "/tmp/${fakeServicesName}";
  fakeEventsFile = "${fakeLogDir}/events.log";
  fakeUploadDir = "${fakeLogDir}/uploads";
  passthroughUploadFile = "${fakeUploadDir}/passthrough.bin";
  compressedUploadFile = "${fakeUploadDir}/compressed.bin";

  fakeBaseUrl = "http://${fakeHost}:${toString fakePort}";
  passthroughMediaPath = "/passthrough.mp4";
  passthroughMediaUrl = "${fakeBaseUrl}${passthroughMediaPath}";
  passthroughMediaWidth = 160;
  passthroughMediaHeight = 90;
  passthroughMediaDuration = 1;
  passthroughVideoFileId = "fake-passthrough-video-file-id";
  passthroughVideoFileUniqueId = "fake-passthrough-video-unique-id";
  compressedMediaPath = "/compressed.mp4";
  compressedMediaUrl = "${fakeBaseUrl}${compressedMediaPath}";
  compressedMediaWidth = 640;
  compressedMediaHeight = 360;
  compressedMediaDuration = 5;
  compressedVideoFileId = "fake-compressed-video-file-id";
  compressedVideoFileUniqueId = "fake-compressed-video-unique-id";
  maxFileSizeToSendToTelegram = 45000000;
  maxVideoSizeToSendToTelegram = 40000000;
  maxAudioSizeToSendToTelegram = 5000000;
  maxFileSizeToCompress = 100000000;
  maxDurationToCompress = 300;
  documentFileId = "fake-document-file-id";
  documentFileUniqueId = "fake-document-unique-id";

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

  nodes.machine =
    { ... }:
    {
      imports = [ module ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.gnugrep
      ];

      services.lolek = {
        enable = true;
        inherit package;
        user = serviceUser;
        group = serviceGroup;
        inherit stateDir downloadDir;
        environmentFile = pkgs.writeText envFileName ''
          LOLEK_BOT_TOKEN=${fakeToken}
        '';
        allowedUrlPatterns = [ fakeHost ];
        maxDownloadDirSize = 0;
        maxDownloadTries = 1;
        startDownloadPause = 10;
        maxDownloadPause = 10;
        inherit
          maxFileSizeToSendToTelegram
          maxVideoSizeToSendToTelegram
          maxAudioSizeToSendToTelegram
          maxFileSizeToCompress
          maxDurationToCompress
          ;
        environment = {
          LOLEK_TELEGRAM_BASE_URL = fakeBaseUrl;
        };
      };

      systemd.services.${fakeServicesName} = {
        description = "Fake external services for Lolek integration test";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LOLEK_FAKE_SERVICES_HOST = fakeHost;
          LOLEK_FAKE_SERVICES_LOG_DIR = fakeLogDir;
          LOLEK_FAKE_SERVICES_EVENTS_FILE = fakeEventsFile;
          LOLEK_FAKE_SERVICES_UPLOAD_DIR = fakeUploadDir;
          LOLEK_FAKE_SERVICES_PASSTHROUGH_MEDIA_PATH = passthroughMediaPath;
          LOLEK_FAKE_SERVICES_PASSTHROUGH_MEDIA_FILE = toString passthroughMediaFile;
          LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_FILE_ID = passthroughVideoFileId;
          LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_FILE_UNIQUE_ID = passthroughVideoFileUniqueId;
          LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_WIDTH = toString passthroughMediaWidth;
          LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_HEIGHT = toString passthroughMediaHeight;
          LOLEK_FAKE_SERVICES_PASSTHROUGH_VIDEO_DURATION = toString passthroughMediaDuration;
          LOLEK_FAKE_SERVICES_COMPRESSED_MEDIA_PATH = compressedMediaPath;
          LOLEK_FAKE_SERVICES_COMPRESSED_MEDIA_FILE = toString compressedMediaFile;
          LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_FILE_ID = compressedVideoFileId;
          LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_FILE_UNIQUE_ID = compressedVideoFileUniqueId;
          LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_WIDTH = toString compressedMediaWidth;
          LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_HEIGHT = toString compressedMediaHeight;
          LOLEK_FAKE_SERVICES_COMPRESSED_VIDEO_DURATION = toString compressedMediaDuration;
          LOLEK_FAKE_SERVICES_PORT = toString fakePort;
          LOLEK_FAKE_SERVICES_TOKEN = fakeToken;
          LOLEK_FAKE_SERVICES_DOCUMENT_FILE_ID = documentFileId;
          LOLEK_FAKE_SERVICES_DOCUMENT_FILE_UNIQUE_ID = documentFileUniqueId;
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./fake-services.py}";
          Restart = "on-failure";
        };
      };

      systemd.services.${serviceName}.wantedBy = pkgs.lib.mkForce [ ];
    };

  testScript = ''
    import base64

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("${fakeServicesUnit}")

    ready_dir_name = "${readyDirName}"
    service_user = "${serviceUser}"
    service_group = "${serviceGroup}"
    download_dir = "${downloadDir}"
    fake_base_url = "${fakeBaseUrl}"
    fake_events_file = "${fakeEventsFile}"
    fake_token = "${fakeToken}"
    passthrough_upload_file = "${passthroughUploadFile}"
    compressed_upload_file = "${compressedUploadFile}"
    max_file_size_to_send_to_telegram = ${toString maxFileSizeToSendToTelegram}
    passthrough_media_file = "${passthroughMediaFile}"
    passthrough_media_url = "${passthroughMediaUrl}"
    passthrough_video_file_id = "${passthroughVideoFileId}"
    compressed_media_file = "${compressedMediaFile}"
    compressed_media_url = "${compressedMediaUrl}"
    compressed_video_file_id = "${compressedVideoFileId}"

    # The module should create the service user, group, and writable download directory.
    machine.succeed("getent passwd %s" % service_user)
    machine.succeed("getent group %s" % service_group)
    machine.succeed("test -d %s" % download_dir)
    machine.succeed("test $(stat -c %%U %s) = %s" % (download_dir, service_user))
    machine.succeed("test $(stat -c %%G %s) = %s" % (download_dir, service_group))
    machine.succeed("su -s /bin/sh %s -c 'test -w %s'" % (service_user, download_dir))

    machine.wait_until_succeeds("curl -fsS %s >/dev/null" % passthrough_media_url)
    machine.wait_until_succeeds("curl -fsS %s >/dev/null" % compressed_media_url)
    machine.wait_until_succeeds("curl -fsS -X POST %s/bot%s/getMe | grep '\"ok\": true'" % (fake_base_url, fake_token))

    machine.succeed("systemctl start ${serviceUnit}")
    machine.wait_for_unit("${serviceUnit}")

    # The first fake update is a small mp4. It should be uploaded without ffmpeg compression.
    machine.wait_until_succeeds("grep '^getUpdates ' %s" % fake_events_file)
    machine.succeed(
        "timeout 120 sh -c 'until grep \"^sendVideo passthrough-upload \" %s; do sleep 1; done' "
        "|| (journalctl -u ${serviceUnit} --no-pager; cat %s; false)"
        % (fake_events_file, fake_events_file)
    )

    # The second fake update repeats the same URL. It should reuse the cached Telegram file ID.
    machine.succeed(
        "timeout 120 sh -c 'until grep \"^sendVideo passthrough-file-id-send \" %s; do sleep 1; done' "
        "|| (journalctl -u ${serviceUnit} --no-pager; cat %s; false)"
        % (fake_events_file, fake_events_file)
    )
    machine.succeed("test $(grep -c '^sendVideo passthrough-upload ' %s) -eq 1" % fake_events_file)
    machine.succeed("test $(grep -c '^sendVideo passthrough-file-id-send ' %s) -eq 1" % fake_events_file)

    # The third fake update is larger than the Telegram send limit. It should go through compression.
    machine.succeed(
        "timeout 120 sh -c 'until grep \"^sendVideo compressed-upload \" %s; do sleep 1; done' "
        "|| (journalctl -u ${serviceUnit} --no-pager; cat %s; false)"
        % (fake_events_file, fake_events_file)
    )
    machine.succeed("test -s %s" % passthrough_upload_file)
    machine.succeed("grep -a 'name=\"video\"' %s" % passthrough_upload_file)
    machine.succeed("grep -a 'ftyp' %s" % passthrough_upload_file)
    machine.succeed("test -s %s" % compressed_upload_file)
    machine.succeed("grep -a 'name=\"video\"' %s" % compressed_upload_file)
    machine.succeed("grep -a 'ftyp' %s" % compressed_upload_file)
    machine.succeed(
        "test $(journalctl -u ${serviceUnit} --no-pager | grep -c 'Compressed video with libx264') -eq 1"
    )

    # Both uploads should be cached under the Telegram file IDs returned by the fake API.
    passthrough_folder_name = base64.b64encode(passthrough_media_url.encode()).decode().rstrip("=")
    passthrough_cache_dir = "%s/%s" % (download_dir, passthrough_folder_name)
    passthrough_ready_file = "%s/%s/%s.mp4" % (
        passthrough_cache_dir,
        ready_dir_name,
        passthrough_video_file_id,
    )
    machine.succeed("test -f %s" % passthrough_ready_file)
    machine.succeed(
        "test $(stat -c %%s %s) -le %d"
        % (passthrough_media_file, max_file_size_to_send_to_telegram)
    )

    compressed_folder_name = base64.b64encode(compressed_media_url.encode()).decode().rstrip("=")
    compressed_cache_dir = "%s/%s" % (download_dir, compressed_folder_name)
    compressed_ready_file = "%s/%s/%s.mp4" % (
        compressed_cache_dir,
        ready_dir_name,
        compressed_video_file_id,
    )
    machine.succeed("test -f %s" % compressed_ready_file)
    machine.succeed(
        "test $(stat -c %%s %s) -gt %d"
        % (compressed_media_file, max_file_size_to_send_to_telegram)
    )
    machine.succeed(
        "test $(stat -c %%s %s) -le %d"
        % (compressed_ready_file, max_file_size_to_send_to_telegram)
    )

    # On-demand cleanup should remove both cache entries while leaving the service alive.
    machine.succeed("${package}/bin/lolek rpc 'Lolek.FileCleaner.cleanup_now()'")
    machine.succeed("test ! -e %s" % passthrough_cache_dir)
    machine.succeed("test ! -e %s" % compressed_cache_dir)
    machine.succeed("systemctl is-active --quiet ${serviceUnit}")
  '';
}
