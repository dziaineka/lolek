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
  envFileName = "${serviceName}.env";

  fakeServicesName = "lolek-concurrency-services";
  fakeServicesUnit = "${fakeServicesName}.service";
  fakeHost = "127.0.0.1";
  fakePort = 8082;
  fakeToken = "dummy-concurrency-token";
  fakeBaseUrl = "http://${fakeHost}:${toString fakePort}";
  metricsPort = 9570;
  metricsUrl = "http://127.0.0.1:${toString metricsPort}/metrics";
  fakeLogDir = "/tmp/${fakeServicesName}";
  fakeEventsFile = "${fakeLogDir}/events.log";
  fakeControlDir = "${fakeLogDir}/control";

  mediaWidth = 160;
  mediaHeight = 90;
  mediaDuration = 1;

  mediaFile =
    pkgs.runCommand "lolek-concurrency-media.mp4" { nativeBuildInputs = [ pkgs.ffmpeg ]; }
      ''
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
  name = "lolek-concurrency";

  containers.machine =
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
        maxConcurrentDownloads = 2;
        maxConcurrentDownloadsPerChat = 1;
        maxVideoRequestsPerChatPerMinute = 2;
        maxDownloadDirSize = 5368709120;
        maxDownloadTries = 1;
        startDownloadPause = 10;
        maxDownloadPause = 10;
        metrics = {
          enable = true;
          port = metricsPort;
        };
        environment = {
          LOLEK_TELEGRAM_BASE_URL = fakeBaseUrl;
        };
      };

      systemd.services.${fakeServicesName} = {
        description = "Fake external services for Lolek concurrency test";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LOLEK_CONCURRENCY_SERVICES_HOST = fakeHost;
          LOLEK_CONCURRENCY_SERVICES_PORT = toString fakePort;
          LOLEK_CONCURRENCY_SERVICES_TOKEN = fakeToken;
          LOLEK_CONCURRENCY_SERVICES_EVENTS_FILE = fakeEventsFile;
          LOLEK_CONCURRENCY_SERVICES_CONTROL_DIR = fakeControlDir;
          LOLEK_CONCURRENCY_SERVICES_MEDIA_FILE = toString mediaFile;
          PYTHONPATH = "${./.}";
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./concurrency-services.py}";
          Restart = "on-failure";
        };
      };

      systemd.services.${serviceName}.wantedBy = pkgs.lib.mkForce [ ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("${fakeServicesUnit}")

    fake_base_url = "${fakeBaseUrl}"
    fake_events_file = "${fakeEventsFile}"
    fake_token = "${fakeToken}"
    fake_control_dir = "${fakeControlDir}"
    metrics_url = "${metricsUrl}"

    def event_count(pattern):
        return (
            "grep -c '%s' %s || true"
            % (pattern.replace("'", "'\"'\"'"), fake_events_file)
        )

    def wait_for_event(pattern):
        machine.wait_until_succeeds("grep '%s' %s" % (pattern, fake_events_file))

    def wait_for_event_count(pattern, expected):
        machine.wait_until_succeeds(
            "test $(%s) -eq %d" % (event_count(pattern), expected)
        )

    def assert_event_count(pattern, expected):
        machine.succeed("test $(%s) -eq %d" % (event_count(pattern), expected))

    def wait_for_metric(line):
        machine.wait_until_succeeds(
            "curl -fsS %s | grep -Fx '%s'" % (metrics_url, line)
        )

    def release_media(name):
        machine.succeed("touch %s/release-%s" % (fake_control_dir, name))

    machine.wait_until_succeeds("curl -fsS -X POST %s/bot%s/getMe | grep '\"ok\": true'" % (fake_base_url, fake_token))

    machine.succeed("systemctl start ${serviceUnit}")
    machine.wait_for_unit("${serviceUnit}")

    # Three updates from different chats should be constrained by the global limit of two.
    wait_for_event("^getUpdates global 3$")
    wait_for_metric("lolek_processing_active 2")
    wait_for_metric("lolek_processing_waiting 1")
    global_starts = "^media-start global-[abc]$"
    wait_for_event_count(global_starts, 2)

    release_media("global-a")
    release_media("global-b")
    release_media("global-c")
    wait_for_event_count(global_starts, 3)
    wait_for_metric("lolek_processing_waiting 0")
    wait_for_event_count("^sendVideo ", 3)

    # Two updates from the same chat should be constrained by the per-chat limit of one,
    # while another chat can still use the remaining global slot.
    machine.succeed("echo per-chat > %s/phase" % fake_control_dir)
    wait_for_event("^getUpdates per-chat 3$")
    wait_for_metric("lolek_processing_active 2")
    wait_for_metric("lolek_processing_waiting 1")
    per_chat_starts = "^media-start chat-[abc]$"
    same_chat_starts = "^media-start chat-[ab]$"
    wait_for_event_count(per_chat_starts, 2)
    wait_for_event("^media-start chat-c$")
    assert_event_count(same_chat_starts, 1)

    release_media("chat-a")
    release_media("chat-b")
    release_media("chat-c")
    wait_for_event_count(per_chat_starts, 3)
    wait_for_metric("lolek_processing_waiting 0")
    wait_for_event_count("^sendVideo ", 6)

    # A burst over the per-chat admission limit should be dropped instead of queued.
    machine.succeed("echo rate-limit > %s/phase" % fake_control_dir)
    wait_for_event("^getUpdates rate-limit 5$")
    wait_for_metric('lolek_chat_rate_limiter_total{result="rejected"} 3')
    wait_for_metric("lolek_processing_active 1")
    wait_for_metric("lolek_processing_waiting 1")
    rate_starts = "^media-start rate-[abcde]$"
    wait_for_event_count(rate_starts, 1)
    release_media("rate-a")
    release_media("rate-b")
    release_media("rate-c")
    release_media("rate-d")
    release_media("rate-e")
    wait_for_event_count(rate_starts, 2)
    wait_for_metric("lolek_processing_waiting 0")
    wait_for_event_count("^sendVideo ", 8)

    machine.succeed("systemctl is-active --quiet ${serviceUnit}")
  '';
}
