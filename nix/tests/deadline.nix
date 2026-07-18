{
  pkgs,
  module,
  package,
}:

let
  serviceName = "lolek";
  serviceUnit = "${serviceName}.service";
  fakeServicesName = "lolek-deadline-services";
  fakeServicesUnit = "${fakeServicesName}.service";
  fakeHost = "127.0.0.1";
  fakePort = 8083;
  fakeToken = "dummy-deadline-token";
  fakeBaseUrl = "http://${fakeHost}:${toString fakePort}";
  fakeEventsFile = "/tmp/${fakeServicesName}/events.log";
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
      imports = [ module ];

      environment.systemPackages = [ pkgs.curl ];

      services.lolek = {
        enable = true;
        package = testPackage;
        botTokenFile = pkgs.writeText "lolek-deadline-test-token" fakeToken;
        allowedUrlPatterns = [ fakeHost ];
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
          LOLEK_TELEGRAM_BASE_URL = fakeBaseUrl;
        };
      };

      systemd.services.${fakeServicesName} = {
        description = "Fake external services for Lolek deadline test";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LOLEK_DEADLINE_SERVICES_HOST = fakeHost;
          LOLEK_DEADLINE_SERVICES_PORT = toString fakePort;
          LOLEK_DEADLINE_SERVICES_TOKEN = fakeToken;
          LOLEK_DEADLINE_SERVICES_EVENTS_FILE = fakeEventsFile;
          PYTHONPATH = "${./.}";
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./deadline-services.py}";
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
    metrics_url = "http://127.0.0.1:${toString metricsPort}/metrics"

    machine.wait_until_succeeds(
        "curl -fsS -X POST %s/bot%s/getMe | grep '\"ok\": true'"
        % (fake_base_url, fake_token)
    )

    machine.succeed("systemctl start ${serviceUnit}")
    machine.wait_for_unit("${serviceUnit}")
    machine.wait_until_succeeds("grep '^getUpdates update$' %s" % fake_events_file)
    machine.wait_until_succeeds("grep '^media-start$' %s" % fake_events_file)

    machine.wait_until_succeeds(
        "journalctl -u ${serviceUnit} --no-pager | grep 'overall deadline exceeded'"
    )
    machine.succeed("sleep 1")
    machine.fail("grep '^telegram-upload ' %s" % fake_events_file)
    machine.succeed("systemctl is-active --quiet ${serviceUnit}")

    machine.wait_until_succeeds(
        "curl -fsS %s | grep -F 'lolek_messages_total{result=\"processing_deadline_exceeded\"} 1'"
        % metrics_url
    )
    machine.wait_until_succeeds(
        "curl -fsS %s | grep -F 'lolek_processing_active 0'" % metrics_url
    )
  '';
}
