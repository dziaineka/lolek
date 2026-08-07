{
  pkgs,
  root,
  systems,
  lolek,
  telegym,
}:

let
  lib = pkgs.lib;
  testCasePython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.requests ]);
  ytDlpTestSource = pkgs.yt-dlp.src;
  galleryDlTestSource = pkgs.gallery-dl.src;
  getTestCasesScript = root + "/scripts/get-test-cases.py";
  corpusPython = pkgs.python3Packages.buildPythonApplication {
    pname = "lolek-corpus";
    version = "0.1.0";
    pyproject = true;
    src = root + "/corpus";
    build-system = [ pkgs.python3Packages.setuptools ];
    dependencies = [ pkgs.python3Packages.pydantic ];
    pythonImportsCheck = [ "lolek_corpus" ];
    checkPhase = ''
      runHook preCheck
      python -m unittest discover -s tests
      runHook postCheck
    '';
    meta.mainProgram = "live-corpus";
  };
  mkCorpusProfile =
    {
      name,
      profile,
      runner,
      description,
      regressionAttempts ? null,
    }:
    let
      arguments = [
        "--profile"
        profile
      ]
      ++ lib.optionals (regressionAttempts != null) [
        "--regression-attempts"
        (toString regressionAttempts)
      ];
    in
    pkgs.writeShellApplication {
      inherit name;
      text = ''
        exec ${lib.getExe runner} ${lib.escapeShellArgs arguments} "$@"
      '';
      meta = {
        inherit description;
        mainProgram = name;
        platforms = systems;
      };
    };
in
rec {
  corpus = corpusPython;

  get-test-cases = pkgs.writeShellApplication {
    name = "get-test-cases";
    text = ''
      export PYTHONPATH="${galleryDlTestSource}:${ytDlpTestSource}"
      exec ${testCasePython}/bin/python3 ${getTestCasesScript} "$@"
    '';
    # TODO: Include Threads once it has an upstream-style test corpus.
    checkPhase = ''
      export PYTHONPATH="${galleryDlTestSource}:${ytDlpTestSource}"
      ${testCasePython}/bin/python3 ${getTestCasesScript} \
        | ${pkgs.jq}/bin/jq --exit-status --slurp \
          '
            (map(.service) | unique) == [
              "coub",
              "facebook",
              "instagram",
              "tiktok",
              "twitter",
              "youtube"
            ] and
            all(.[];
              (.id | test("^[a-z0-9-]+-[0-9a-f]{16}$")) and
              (.url | type == "string" and length > 0) and
              (.sources | type == "array" and length > 0) and
              (.kinds | type == "array" and length > 0)
            ) and
            (map(.id) | length) == (map(.id) | unique | length) and
            (map(.url) | length) == (map(.url) | unique | length)
          ' >/dev/null
    '';
  };

  test-corpus = pkgs.runCommand "lolek-upstream-test-corpus.jsonl" { } ''
    ${lib.getExe get-test-cases} > "$out"
  '';

  live-corpus = pkgs.writeShellApplication {
    name = "live-corpus";
    text = ''
      exec ${lib.getExe corpusPython} \
        --corpus ${test-corpus} \
        --lolek ${lolek}/bin/lolek \
        --telegym ${telegym}/bin/telegym-mock \
        --ffprobe ${pkgs.ffmpeg-full}/bin/ffprobe \
        "$@"
    '';
    meta = {
      description = "Run Lolek's upstream corpus against live media services";
      mainProgram = "live-corpus";
      platforms = systems;
    };
  };

  live-corpus-check = mkCorpusProfile {
    name = "live-corpus-check";
    profile = "no-gallery";
    runner = live-corpus;
    regressionAttempts = 2;
    description = "Detect regressions in Lolek's live yt-dlp corpus";
  };

  live-corpus-gallery = mkCorpusProfile {
    name = "live-corpus-gallery";
    profile = "gallery";
    runner = live-corpus;
    description = "Run Lolek's live gallery-dl corpus";
  };

  live-corpus-gallery-check = mkCorpusProfile {
    name = "live-corpus-gallery-check";
    profile = "gallery";
    runner = live-corpus;
    regressionAttempts = 2;
    description = "Detect regressions in Lolek's live gallery-dl corpus";
  };
}
