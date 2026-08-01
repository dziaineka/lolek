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
  envFileName = "${serviceName}.env";

  mediaOriginName = "lolek-concurrency-media-origin";
  mediaOriginUnit = "${mediaOriginName}.service";
  testHost = "127.0.0.1";
  mediaOriginPort = 8082;
  mediaOriginBaseUrl = "http://${testHost}:${toString mediaOriginPort}";
  telegymPort = 5678;
  telegymBaseUrl = "http://${testHost}:${toString telegymPort}";
  telegymUnit = "telegym-mock.service";
  fakeToken = "dummy-concurrency-token";
  metricsPort = 9570;
  metricsUrl = "http://127.0.0.1:${toString metricsPort}/metrics";
  mediaOriginLogDir = "/tmp/${mediaOriginName}";
  mediaOriginEventsFile = "${mediaOriginLogDir}/events.log";
  mediaOriginControlDir = "${mediaOriginLogDir}/control";

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
        environmentFile = pkgs.writeText envFileName ''
          LOLEK_BOT_TOKEN=${fakeToken}
        '';
        allowedUrlPatterns = [ testHost ];
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
          LOLEK_TELEGRAM_BASE_URL = telegymBaseUrl;
        };
      };

      systemd.services.${mediaOriginName} = {
        description = "Media origin for Lolek concurrency test";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LOLEK_CONCURRENCY_ORIGIN_HOST = testHost;
          LOLEK_CONCURRENCY_ORIGIN_PORT = toString mediaOriginPort;
          LOLEK_CONCURRENCY_ORIGIN_EVENTS_FILE = mediaOriginEventsFile;
          LOLEK_CONCURRENCY_ORIGIN_CONTROL_DIR = mediaOriginControlDir;
          LOLEK_CONCURRENCY_ORIGIN_MEDIA_FILE = toString mediaFile;
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./concurrency-media-origin.py}";
          Restart = "on-failure";
        };
      };

      systemd.services.${serviceName}.wantedBy = pkgs.lib.mkForce [ ];
    };

  testScript = ''
    import json
    import shlex

    def shell_quote(value):
        return shlex.quote(value)

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("${mediaOriginUnit}")
    machine.wait_for_unit("${telegymUnit}")

    media_origin_base_url = "${mediaOriginBaseUrl}"
    media_origin_events_file = "${mediaOriginEventsFile}"
    fake_token = "${fakeToken}"
    media_origin_control_dir = "${mediaOriginControlDir}"
    metrics_url = "${metricsUrl}"
    telegym_base_url = "${telegymBaseUrl}"
    messages_url = "%s/debug/messages/%s" % (telegym_base_url, fake_token)

    def media_url(name):
        return "%s/media/%s.mp4" % (media_origin_base_url, name)

    def inject(name, chat_id):
        payload = json.dumps(
            {"token": fake_token, "chat_id": chat_id, "text": media_url(name)},
            separators=(",", ":"),
        )
        machine.succeed(
            "curl -fsS -H 'Content-Type: application/json' --data %s "
            "%s/debug/inject/update | "
            "jq -e '.ok and .delivery_method == \"polling\"' >/dev/null"
            % (shell_quote(payload), telegym_base_url)
        )

    def event_count(pattern):
        return (
            "grep -c '%s' %s || true"
            % (pattern.replace("'", "'\"'\"'"), media_origin_events_file)
        )

    def wait_for_event(pattern):
        machine.wait_until_succeeds(
            "grep '%s' %s" % (pattern, media_origin_events_file)
        )

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
        machine.succeed("touch %s/release-%s" % (media_origin_control_dir, name))

    def wait_for_video_count(expected):
        machine.wait_until_succeeds(
            "curl -fsS %s | "
            "jq -e '[.messages[] | select(.video != null)] | length == %d' "
            ">/dev/null" % (shell_quote(messages_url), expected)
        )

    machine.wait_until_succeeds(
        "curl -fsSI %s >/dev/null" % media_url("global-a")
    )
    machine.wait_until_succeeds(
        "curl -fsS %s/health | jq -e '.status == \"ok\"' >/dev/null"
        % telegym_base_url
    )

    machine.succeed("systemctl start ${serviceUnit}")
    machine.wait_for_unit("${serviceUnit}")
    machine.wait_until_succeeds(
        "curl -fsS %s/debug/bots | "
        "jq -e --arg token %s '.bots | any(.token_full == $token)' >/dev/null"
        % (telegym_base_url, shell_quote(fake_token))
    )

    # Three updates from different chats should be constrained by the global limit of two.
    inject("global-a", 1001)
    wait_for_event("^media-start global-a$")
    inject("global-b", 1002)
    wait_for_event("^media-start global-b$")
    inject("global-c", 1003)
    wait_for_metric("lolek_processing_active 2")
    wait_for_metric("lolek_processing_waiting 1")
    global_starts = "^media-start global-[abc]$"
    wait_for_event_count(global_starts, 2)

    release_media("global-a")
    release_media("global-b")
    release_media("global-c")
    wait_for_event_count(global_starts, 3)
    wait_for_metric("lolek_processing_waiting 0")
    wait_for_video_count(3)
    wait_for_metric("lolek_processing_active 0")

    # Two updates from the same chat should be constrained by the per-chat limit of one,
    # while another chat can still use the remaining global slot.
    inject("chat-a", 2001)
    wait_for_event("^media-start chat-a$")
    inject("chat-b", 2001)
    inject("chat-c", 2002)
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
    wait_for_video_count(6)
    wait_for_metric("lolek_processing_active 0")

    # A burst over the per-chat admission limit should be dropped instead of queued.
    inject("rate-a", 3001)
    wait_for_event("^media-start rate-a$")
    inject("rate-b", 3001)
    inject("rate-c", 3001)
    inject("rate-d", 3001)
    inject("rate-e", 3001)
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
    wait_for_video_count(8)
    wait_for_metric("lolek_processing_active 0")

    machine.succeed("systemctl is-active --quiet ${serviceUnit}")
  '';
}
