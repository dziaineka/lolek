{
  pkgs,
  module,
  package,
  telegym,
  testCases,
}:

let
  lib = pkgs.lib;
  serviceName = "lolek";
  serviceUnit = "${serviceName}.service";
  stateDir = "/var/lib/lolek";
  downloadDir = "${stateDir}/downloads";
  originName = "lolek-corpus-media-origin";
  originUnit = "${originName}.service";
  testHost = "127.0.0.1";
  originPort = 8084;
  originBaseUrl = "http://${testHost}:${toString originPort}";
  telegymPort = 5678;
  telegymBaseUrl = "http://${testHost}:${toString telegymPort}";
  telegymUnit = "telegym-mock.service";
  fakeToken = "dummy-corpus-token";
  metricsPort = 9570;

  corpus = pkgs.runCommand "lolek-upstream-test-corpus.jsonl" { } ''
    ${lib.getExe testCases} > "$out"
  '';

  mkImageFixture =
    name: size: color:
    pkgs.runCommand "lolek-corpus-${name}" { nativeBuildInputs = [ pkgs.ffmpeg ]; } ''
      ffmpeg \
        -loglevel error \
        -f lavfi -i color=c=${color}:s=${size} \
        -frames:v 1 \
        -c:v mjpeg \
        -f image2 \
        "$out"
    '';

  mkVideoFixture =
    name: size:
    pkgs.runCommand "lolek-corpus-${name}" { nativeBuildInputs = [ pkgs.ffmpeg ]; } ''
      ffmpeg \
        -loglevel error \
        -f lavfi -i testsrc=size=${size}:rate=5 \
        -f lavfi -i anullsrc=channel_layout=mono:sample_rate=44100 \
        -t 1 \
        -pix_fmt yuv420p \
        -c:v libx264 \
        -preset ultrafast \
        -c:a aac \
        -movflags +faststart \
        -f mp4 \
        "$out"
    '';

  fixtureFiles = {
    "landscape.jpg" = mkImageFixture "landscape.jpg" "160x90" "blue";
    "portrait.jpg" = mkImageFixture "portrait.jpg" "90x160" "green";
    "square.jpg" = mkImageFixture "square.jpg" "128x128" "orange";
    "landscape.mp4" = mkVideoFixture "landscape.mp4" "160x90";
    "portrait.mp4" = mkVideoFixture "portrait.mp4" "90x160";
  };
  fixtureManifest = pkgs.writeText "lolek-corpus-fixtures.json" (
    builtins.toJSON (lib.mapAttrs (_name: path: toString path) fixtureFiles)
  );

  fakeGalleryDl = pkgs.writeShellApplication {
    name = "gallery-dl";
    text = ''
      export PYTHONPATH=${./.}
      exec ${pkgs.python3}/bin/python3 ${./corpus-gallery-dl.py} "$@"
    '';
  };
  fakeYtDlp = pkgs.writeShellApplication {
    name = "yt-dlp";
    text = ''
      export PYTHONPATH=${./.}
      exec ${pkgs.python3}/bin/python3 ${./corpus-yt-dlp.py} "$@"
    '';
  };
  testPackage = package.override {
    gallery-dl = fakeGalleryDl;
    yt-dlp = fakeYtDlp;
  };
in
pkgs.testers.nixosTest {
  name = "lolek-corpus";

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
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];

      services.lolek = {
        enable = true;
        package = testPackage;
        inherit stateDir downloadDir;
        botTokenFile = pkgs.writeText "lolek-corpus-test-token" fakeToken;
        galleryDownloadEnabled = true;
        maxDownloadDirSize = 0;
        maxConcurrentDownloads = 2;
        maxConcurrentDownloadsPerChat = 1;
        maxVideoRequestsPerChatPerMinute = 1000;
        maxMessageDelaySeconds = 900;
        maxDownloadTries = 1;
        startDownloadPause = 10;
        maxDownloadPause = 10;
        metrics = {
          enable = true;
          port = metricsPort;
        };
        environment = {
          LOLEK_TELEGRAM_BASE_URL = telegymBaseUrl;
          LOLEK_TEST_CORPUS_ORIGIN = originBaseUrl;
          LOLEK_TEST_CORPUS_PATH = toString corpus;
        };
      };

      systemd.services.${originName} = {
        description = "Media origin for the Lolek upstream corpus test";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LOLEK_TEST_CORPUS_FIXTURE_MANIFEST = toString fixtureManifest;
          LOLEK_TEST_CORPUS_ORIGIN_HOST = testHost;
          LOLEK_TEST_CORPUS_ORIGIN_PORT = toString originPort;
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./corpus-media-origin.py}";
          Restart = "on-failure";
        };
      };

      systemd.services.${serviceName}.wantedBy = lib.mkForce [ ];
    };

  testScript = ''
    ${builtins.readFile ./corpus_test_common.py}

    import collections
    import shlex

    expectations = json.loads(
        open(
            "${../../corpus/src/lolek_corpus/data/expectations.json}",
            encoding="utf-8",
        ).read()
    )
    excluded_case_ids = set(expectations["default_rejected"])

    def shell_quote(value):
        return shlex.quote(value)

    def inject(case, chat_id):
        payload = json.dumps(
            {
                "token": fake_token,
                "chat_id": chat_id,
                "username": "corpus_test",
                "first_name": "Corpus Test",
                "text": case["url"],
            },
            separators=(",", ":"),
        )
        machine.succeed(
            "curl -fsS -H 'Content-Type: application/json' --data %s "
            "%s/debug/inject/update | "
            "jq -e '.ok and .delivery_method == \"polling\"' >/dev/null"
            % (shell_quote(payload), telegym_base_url)
        )

    def messages_url(chat_id):
        return "%s/debug/messages/%s?chat_id=%d" % (
            telegym_base_url,
            fake_token,
            chat_id,
        )

    def wait_for_messages(chat_id, expected_count):
        url = messages_url(chat_id)
        machine.wait_until_succeeds(
            "curl -fsS %s | jq -e '.count == %d' >/dev/null"
            % (shell_quote(url), expected_count),
            timeout=60,
        )
        return json.loads(machine.succeed("curl -fsS %s" % shell_quote(url)))[
            "messages"
        ]

    def wait_for_idle():
        machine.wait_until_succeeds(
            "curl -fsS %s | grep -F 'lolek_processing_active 0' >/dev/null"
            % metrics_url
        )

    def message_kind(message):
        if message.get("video"):
            return "video"
        if message.get("photo"):
            return "photo"
        raise AssertionError("unexpected corpus message: %r" % message)

    def message_file_id(message):
        if message.get("video"):
            return message["video"]["file_id"]
        if message.get("photo"):
            return message["photo"][-1]["file_id"]
        raise AssertionError("message has no media file ID: %r" % message)

    def file_sha256(path):
        return machine.succeed("sha256sum %s" % shell_quote(path)).split()[0]

    def uploaded_sha256(file_id):
        return machine.succeed(
            "curl -fsS %s/debug/files/%s | sha256sum"
            % (telegym_base_url, shell_quote(file_id))
        ).split()[0]

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("${originUnit}")
    machine.wait_for_unit("${telegymUnit}")

    corpus_path = "${corpus}"
    fixture_paths = json.loads(open("${fixtureManifest}", encoding="utf-8").read())
    cases = load_cases(corpus_path)
    cases_by_id = {case["id"]: case for case in cases}
    assert excluded_case_ids <= cases_by_id.keys()
    accepted_cases = [case for case in cases if case["id"] not in excluded_case_ids]
    rejected_cases = [case for case in cases if case["id"] in excluded_case_ids]
    assert len(cases) == len(accepted_cases) + len(rejected_cases)

    fake_token = "${fakeToken}"
    metrics_url = "http://127.0.0.1:${toString metricsPort}/metrics"
    origin_base_url = "${originBaseUrl}"
    telegym_base_url = "${telegymBaseUrl}"

    machine.wait_until_succeeds(
        "curl -fsS %s/health | jq -e '.status == \"ok\"' >/dev/null"
        % origin_base_url
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

    first_case_messages = []
    first_case = accepted_cases[0]

    for index, case in enumerate(accepted_cases, start=1):
        with subtest(case["id"]):
            case_scenario = scenario(case)
            fixtures = case_scenario["fixtures"]
            chat_id = 20000 + index
            inject(case, chat_id)
            messages = wait_for_messages(chat_id, len(fixtures))
            wait_for_idle()

            expected_kinds = sorted(
                fixture_kind(fixture) for fixture in fixtures
            )
            assert sorted(message_kind(message) for message in messages) == expected_kinds

            expected_hashes = sorted(file_sha256(fixture_paths[name]) for name in fixtures)
            uploaded_hashes = sorted(
                uploaded_sha256(message_file_id(message)) for message in messages
            )
            assert uploaded_hashes == expected_hashes

            if case == first_case:
                first_case_messages = messages

    for index, case in enumerate(rejected_cases, start=1):
        inject(case, 40000 + index)

    machine.wait_until_succeeds(
        "curl -fsS %s | "
        "grep -F 'lolek_messages_total{result=\"no_url\"} %d' >/dev/null"
        % (metrics_url, len(rejected_cases))
    )
    wait_for_idle()

    for index, _case in enumerate(rejected_cases, start=1):
        machine.succeed(
            "curl -fsS %s | jq -e '.count == 0' >/dev/null"
            % shell_quote(messages_url(40000 + index))
        )

    events_response = json.loads(
        machine.succeed("curl -fsS %s/debug/events" % origin_base_url)
    )
    events = events_response["events"]
    events_by_case = collections.defaultdict(list)
    for event in events:
        events_by_case[event["case_id"]].append(event)

    for case in accepted_cases:
        case_scenario = scenario(case)
        case_events = events_by_case[case["id"]]
        event_types = collections.Counter(event["type"] for event in case_events)
        assert event_types["metadata"] == 1, case_events
        assert event_types["gallery"] == 1, case_events
        assert event_types["formats"] == 0, case_events
        assert event_types["media"] == len(case_scenario["fixtures"]), case_events

        if case_scenario["route"] == "gallery-dl":
            assert event_types["download"] == 0, case_events
            assert any(
                event["type"] == "gallery" and event["handled"]
                for event in case_events
            )
        else:
            assert event_types["download"] == 1, case_events
            assert any(
                event["type"] == "gallery" and not event["handled"]
                for event in case_events
            )

    for case in rejected_cases:
        assert events_by_case[case["id"]] == []

    events_before_cache_hit = len(events)
    cache_chat_id = 50000
    inject(first_case, cache_chat_id)
    cached_messages = wait_for_messages(
        cache_chat_id,
        len(scenario(first_case)["fixtures"]),
    )
    wait_for_idle()
    assert sorted(message_file_id(message) for message in cached_messages) == sorted(
        message_file_id(message) for message in first_case_messages
    )
    events_after_cache_hit = json.loads(
        machine.succeed("curl -fsS %s/debug/events" % origin_base_url)
    )["events"]
    assert len(events_after_cache_hit) == events_before_cache_hit

    machine.succeed("systemctl is-active --quiet ${serviceUnit}")
  '';
}
