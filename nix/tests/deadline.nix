{
  pkgs,
  module,
  package,
  telegym,
}:

let
  serviceName = "lolek";
  serviceUnit = "${serviceName}.service";
  mediaOriginName = "lolek-deadline-media-origin";
  mediaOriginUnit = "${mediaOriginName}.service";
  testHost = "127.0.0.1";
  mediaOriginPort = 8083;
  mediaOriginBaseUrl = "http://${testHost}:${toString mediaOriginPort}";
  mediaPath = "/media/deadline.mp4";
  mediaUrl = "${mediaOriginBaseUrl}${mediaPath}";
  telegymPort = 5678;
  telegymBaseUrl = "http://${testHost}:${toString telegymPort}";
  telegymUnit = "telegym-mock.service";
  fakeToken = "dummy-deadline-token";
  mediaOriginEventsFile = "/tmp/${mediaOriginName}/events.log";
  metricsPort = 9569;
  fakeYtDlp = pkgs.writeShellApplication {
    name = "yt-dlp";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      url=""

      for argument in "$@"; do
        if [[ "$argument" == "--dump-single-json" ]]; then
          printf '%s\n' '{"title":"Deadline media","description":"Deadline test media"}'
          exit 0
        fi

        url="$argument"
      done

      exec curl --fail --silent --show-error "$url"
    '';
  };
  testPackage = package.override { yt-dlp = fakeYtDlp; };
in
pkgs.testers.nixosTest {
  name = "lolek-deadline";

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
        pkgs.jq
      ];

      services.lolek = {
        enable = true;
        package = testPackage;
        botTokenFile = pkgs.writeText "lolek-deadline-test-token" fakeToken;
        allowedUrlPatterns = [ testHost ];
        maxMessageDelaySeconds = 2;
        downloadCommandTimeout = 30;
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
        description = "Media origin for Lolek deadline test";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LOLEK_DEADLINE_ORIGIN_HOST = testHost;
          LOLEK_DEADLINE_ORIGIN_PORT = toString mediaOriginPort;
          LOLEK_DEADLINE_ORIGIN_EVENTS_FILE = mediaOriginEventsFile;
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./deadline-media-origin.py}";
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

    media_origin_events_file = "${mediaOriginEventsFile}"
    media_url = "${mediaUrl}"
    fake_token = "${fakeToken}"
    metrics_url = "http://127.0.0.1:${toString metricsPort}/metrics"
    telegym_base_url = "${telegymBaseUrl}"
    messages_url = "%s/debug/messages/%s" % (telegym_base_url, fake_token)

    machine.wait_until_succeeds(
        "curl -fsSI %s >/dev/null" % shell_quote(media_url)
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

    payload = json.dumps(
        {"token": fake_token, "chat_id": 1001, "text": media_url},
        separators=(",", ":"),
    )
    machine.succeed(
        "curl -fsS -H 'Content-Type: application/json' --data %s "
        "%s/debug/inject/update | "
        "jq -e '.ok and .delivery_method == \"polling\"' >/dev/null"
        % (shell_quote(payload), telegym_base_url)
    )
    machine.wait_until_succeeds(
        "grep '^media-start$' %s" % media_origin_events_file
    )

    machine.wait_until_succeeds(
        "journalctl -u ${serviceUnit} --no-pager | grep 'overall deadline exceeded'"
    )
    machine.wait_until_succeeds(
        "curl -fsS %s | grep -F 'lolek_messages_total{result=\"processing_deadline_exceeded\"} 1'"
        % metrics_url
    )
    machine.wait_until_succeeds(
        "curl -fsS %s | grep -F 'lolek_processing_active 0'" % metrics_url
    )
    machine.succeed(
        "curl -fsS %s | jq -e '.count == 0' >/dev/null"
        % shell_quote(messages_url)
    )
    machine.succeed("systemctl is-active --quiet ${serviceUnit}")
  '';
}
