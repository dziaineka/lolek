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
  fakeUploadFile = "${fakeLogDir}/upload.bin";

  mediaPath = "/media.mp4";
  fakeBaseUrl = "http://${fakeHost}:${toString fakePort}";
  fakeAllowedUrlsRegex = pkgs.lib.escapeRegex fakeHost;
  mediaUrl = "${fakeBaseUrl}${mediaPath}";
  mediaWidth = 160;
  mediaHeight = 90;
  mediaDuration = 1;
  videoFileId = "fake-video-file-id";
  videoFileUniqueId = "fake-video-unique-id";
  documentFileId = "fake-document-file-id";
  documentFileUniqueId = "fake-document-unique-id";

  mediaFile = pkgs.runCommand "lolek-test-media.mp4" { nativeBuildInputs = [ pkgs.ffmpeg ]; } ''
    ffmpeg \
      -f lavfi -i testsrc=size=${toString mediaWidth}x${toString mediaHeight}:rate=10 \
      -f lavfi -i anullsrc=channel_layout=mono:sample_rate=44100 \
      -t ${toString mediaDuration} \
      -pix_fmt yuv420p \
      -c:v libx264 \
      -preset ultrafast \
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
        environment = {
          LOLEK_TELEGRAM_BASE_URL = fakeBaseUrl;
          LOLEK_ALLOWED_URLS_REGEX = fakeAllowedUrlsRegex;
          LOLEK_MAX_DOWNLOAD_TRIES = "1";
          LOLEK_START_DOWNLOAD_PAUSE = "10";
          LOLEK_MAX_DOWNLOAD_PAUSE = "10";
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
          LOLEK_FAKE_SERVICES_UPLOAD_FILE = fakeUploadFile;
          LOLEK_FAKE_SERVICES_MEDIA_PATH = mediaPath;
          LOLEK_FAKE_SERVICES_MEDIA_FILE = toString mediaFile;
          LOLEK_FAKE_SERVICES_PORT = toString fakePort;
          LOLEK_FAKE_SERVICES_TOKEN = fakeToken;
          LOLEK_FAKE_SERVICES_VIDEO_FILE_ID = videoFileId;
          LOLEK_FAKE_SERVICES_VIDEO_FILE_UNIQUE_ID = videoFileUniqueId;
          LOLEK_FAKE_SERVICES_VIDEO_WIDTH = toString mediaWidth;
          LOLEK_FAKE_SERVICES_VIDEO_HEIGHT = toString mediaHeight;
          LOLEK_FAKE_SERVICES_VIDEO_DURATION = toString mediaDuration;
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
    fake_upload_file = "${fakeUploadFile}"
    media_url = "${mediaUrl}"
    video_file_id = "${videoFileId}"

    machine.succeed("getent passwd %s" % service_user)
    machine.succeed("getent group %s" % service_group)
    machine.succeed("test -d %s" % download_dir)
    machine.succeed("test $(stat -c %%U %s) = %s" % (download_dir, service_user))
    machine.succeed("test $(stat -c %%G %s) = %s" % (download_dir, service_group))
    machine.succeed("su -s /bin/sh %s -c 'test -w %s'" % (service_user, download_dir))

    machine.wait_until_succeeds("curl -fsS %s >/dev/null" % media_url)
    machine.wait_until_succeeds("curl -fsS -X POST %s/bot%s/getMe | grep '\"ok\": true'" % (fake_base_url, fake_token))

    machine.succeed("systemctl start ${serviceUnit}")
    machine.wait_for_unit("${serviceUnit}")

    machine.wait_until_succeeds("grep '^getUpdates ' %s" % fake_events_file)
    machine.succeed(
        "timeout 120 sh -c 'until grep \"^sendVideo \" %s; do sleep 1; done' "
        "|| (journalctl -u ${serviceUnit} --no-pager; cat %s; false)"
        % (fake_events_file, fake_events_file)
    )
    machine.succeed("test -s %s" % fake_upload_file)
    machine.succeed("grep -a 'name=\"video\"' %s" % fake_upload_file)
    machine.succeed("grep -a 'ftyp' %s" % fake_upload_file)

    folder_name = base64.b64encode(media_url.encode()).decode().rstrip("=")
    machine.succeed("test -f %s/%s/%s/%s.mp4" % (download_dir, folder_name, ready_dir_name, video_file_id))
  '';
}
