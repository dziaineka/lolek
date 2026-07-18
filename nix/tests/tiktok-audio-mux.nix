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

  fakeServicesName = "lolek-tiktok-audio-services";
  fakeServicesUnit = "${fakeServicesName}.service";
  fakeHost = "127.0.0.1";
  fakePort = 8083;
  fakeToken = "dummy-tiktok-audio-token";
  fakeBaseUrl = "http://${fakeHost}:${toString fakePort}";
  fakeLogDir = "/tmp/${fakeServicesName}";
  fakeEventsFile = "${fakeLogDir}/events.log";
  uploadFile = "${fakeLogDir}/upload.bin";

  mediaPath = "/tiktok-post";
  mediaUrl = "${fakeBaseUrl}${mediaPath}";
  audioPath = "/tiktok-audio.mp4";
  audioUrl = "${fakeBaseUrl}${audioPath}";
  missingAudioUrl = "${fakeBaseUrl}/missing-tiktok-audio.mp4";
  mediaWidth = 160;
  mediaHeight = 90;
  mediaDuration = 2;
  videoFileId = "fake-tiktok-video-file-id";
  videoFileUniqueId = "fake-tiktok-video-file-unique-id";

  videoOnlyFile =
    pkgs.runCommand "lolek-test-tiktok-video-only.mp4" { nativeBuildInputs = [ pkgs.ffmpeg ]; }
      ''
        ffmpeg \
          -f lavfi -i testsrc=size=${toString mediaWidth}x${toString mediaHeight}:rate=10 \
          -t ${toString mediaDuration} \
          -pix_fmt yuv420p \
          -c:v libx264 \
          -preset ultrafast \
          -an \
          -movflags +faststart \
          "$out"
      '';

  audioFile =
    pkgs.runCommand "lolek-test-tiktok-audio.mp4" { nativeBuildInputs = [ pkgs.ffmpeg ]; }
      ''
        ffmpeg \
          -f lavfi -i sine=frequency=440:sample_rate=44100 \
          -t ${toString mediaDuration} \
          -vn \
          -c:a aac \
          -movflags +faststart \
          "$out"
      '';

  fakeGalleryDl = pkgs.writeShellScriptBin "gallery-dl" ''
    set -eu

    dest=
    url=

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dest)
          shift
          dest="$1"
          ;;
        --cookies|--config|-o)
          shift
          ;;
        --*)
          ;;
        *)
          url="$1"
          ;;
      esac
      shift
    done

    if [ "$url" != "${mediaUrl}" ]; then
      exit 0
    fi

    if [ -z "$dest" ]; then
      echo "gallery-dl test double requires --dest" >&2
      exit 2
    fi

    target="$dest/tiktok/fakeuser"
    mkdir -p "$target"
    cp "${videoOnlyFile}" "$target/video-only.mp4"

    # gallery-dl can save TikTok adaptive video separately from the audio URL
    # metadata. The service should repair that backend output before Telegram
    # upload and cache handling see the MP4 as complete.
    # The first URL is intentionally missing because TikTok signs multiple
    # equivalent audio URLs and CDN/client acceptance can differ between them.
    cat > "$target/video-only.json" <<'JSON'
    {
      "category": "tiktok",
      "video": {
        "bitrateAudioInfo": [
          {
            "Bitrate": 64000,
            "UrlList": {
              "FallbackUrl": "${missingAudioUrl}",
              "MainUrl": "${audioUrl}",
              "BackupUrl": "${audioUrl}"
            }
          }
        ]
      },
      "music": {
        "playUrl": "${audioUrl}"
      }
    }
    JSON
  '';

  packageWithFakeGalleryDl = package.override {
    gallery-dl = fakeGalleryDl;
  };
in
pkgs.testers.nixosTest {
  name = "lolek-tiktok-audio-mux";

  nodes.machine =
    { ... }:
    {
      imports = [ module ];

      environment.systemPackages = [
        pkgs.curl
        pkgs.ffmpeg
        pkgs.gnugrep
      ];

      services.lolek = {
        enable = true;
        package = packageWithFakeGalleryDl;
        user = serviceUser;
        group = serviceGroup;
        inherit stateDir downloadDir;
        botTokenFile = pkgs.writeText "lolek-tiktok-audio-test-token" fakeToken;
        allowedUrlPatterns = [ fakeHost ];
        maxDownloadDirSize = 0;
        maxConcurrentDownloads = 1;
        maxConcurrentDownloadsPerChat = 1;
        maxDownloadTries = 1;
        startDownloadPause = 10;
        maxDownloadPause = 10;
        galleryDownloadEnabled = true;
        environment = {
          LOLEK_TELEGRAM_BASE_URL = fakeBaseUrl;
        };
      };

      systemd.services.${fakeServicesName} = {
        description = "Fake external services for Lolek TikTok audio mux test";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LOLEK_TIKTOK_AUDIO_SERVICES_HOST = fakeHost;
          LOLEK_TIKTOK_AUDIO_SERVICES_PORT = toString fakePort;
          LOLEK_TIKTOK_AUDIO_SERVICES_TOKEN = fakeToken;
          LOLEK_TIKTOK_AUDIO_SERVICES_EVENTS_FILE = fakeEventsFile;
          LOLEK_TIKTOK_AUDIO_SERVICES_UPLOAD_FILE = uploadFile;
          LOLEK_TIKTOK_AUDIO_SERVICES_MEDIA_PATH = mediaPath;
          LOLEK_TIKTOK_AUDIO_SERVICES_MEDIA_FILE = toString videoOnlyFile;
          LOLEK_TIKTOK_AUDIO_SERVICES_AUDIO_PATH = audioPath;
          LOLEK_TIKTOK_AUDIO_SERVICES_AUDIO_FILE = toString audioFile;
          LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_FILE_ID = videoFileId;
          LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_FILE_UNIQUE_ID = videoFileUniqueId;
          LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_WIDTH = toString mediaWidth;
          LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_HEIGHT = toString mediaHeight;
          LOLEK_TIKTOK_AUDIO_SERVICES_VIDEO_DURATION = toString mediaDuration;
          PYTHONPATH = "${./.}";
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./tiktok-audio-services.py}";
          Restart = "on-failure";
        };
      };

      systemd.services.${serviceName}.wantedBy = pkgs.lib.mkForce [ ];
    };

  testScript = ''
    import base64
    import shlex

    def shell_quote(value):
        return shlex.quote(value)

    def stream_count_command(selector, path):
        return (
            "ffprobe -v error -select_streams %s "
            "-show_entries stream=index -of csv=p=0 %s | wc -l"
            % (selector, shell_quote(path))
        )

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("${fakeServicesUnit}")

    fake_base_url = "${fakeBaseUrl}"
    fake_events_file = "${fakeEventsFile}"
    fake_token = "${fakeToken}"
    media_url = "${mediaUrl}"
    audio_url = "${audioUrl}"
    download_dir = "${downloadDir}"
    ready_dir_name = "${readyDirName}"
    video_file_id = "${videoFileId}"
    upload_file = "${uploadFile}"
    folder_name = base64.b64encode(media_url.encode()).decode().rstrip("=")
    cache_dir = "%s/%s" % (download_dir, folder_name)
    ready_file = "%s/%s/%s.mp4" % (cache_dir, ready_dir_name, video_file_id)

    machine.wait_until_succeeds("curl -fsS %s >/dev/null" % media_url)
    machine.wait_until_succeeds("curl -fsS %s >/dev/null" % audio_url)
    machine.wait_until_succeeds("curl -fsS -X POST %s/bot%s/getMe | grep '\"ok\": true'" % (fake_base_url, fake_token))

    machine.succeed("systemctl start ${serviceUnit}")
    machine.wait_for_unit("${serviceUnit}")

    machine.succeed(
        "timeout 120 sh -c 'until grep \"^sendVideo upload \" %s; do sleep 1; done' "
        "|| (journalctl -u ${serviceUnit} --no-pager; cat %s; false)"
        % (fake_events_file, fake_events_file)
    )

    machine.succeed("test -s %s" % upload_file)
    machine.succeed("grep -aq 'name=\"video\"' %s" % upload_file)
    machine.succeed("grep -aq 'ftyp' %s" % upload_file)
    machine.wait_until_succeeds("test -f %s" % shell_quote(ready_file))
    machine.succeed("test $(%s) -eq 1" % stream_count_command("v", ready_file))
    machine.succeed("test $(%s) -eq 1" % stream_count_command("a", ready_file))
    machine.succeed(
        "test $(ffprobe -v error -select_streams a:0 "
        "-show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 %s) = aac"
        % shell_quote(ready_file)
    )
    machine.succeed(
        "journalctl -u ${serviceUnit} --no-pager | grep 'TikTok audio mux attempt failed'"
    )
    machine.succeed(
        "journalctl -u ${serviceUnit} --no-pager | grep 'Muxed TikTok audio into gallery video'"
    )
    machine.succeed("systemctl is-active --quiet ${serviceUnit}")
  '';
}
