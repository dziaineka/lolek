{
  pkgs,
  root,
  systems,
}:

let
  lib = pkgs.lib;
  beamPackages = pkgs.beam.packages.erlang_29;
  elixir = beamPackages.elixir_1_20;
  rebar3WithPlugins = beamPackages.rebar3WithPlugins {
    globalPlugins = [ beamPackages.pc ];
  };
  fetchMixDeps = beamPackages.fetchMixDeps.override {
    rebar3 = rebar3WithPlugins;
  };
  mixRelease = beamPackages.mixRelease.override {
    makeWrapper = pkgs.makeBinaryWrapper;
    rebar3 = rebar3WithPlugins;
  };
  sourceFiles =
    extraFiles:
    lib.fileset.unions (
      [
        (root + "/config")
        (root + "/lib")
        (root + "/mix.exs")
        (root + "/mix.lock")
      ]
      ++ extraFiles
    );
  src = lib.fileset.toSource {
    inherit root;
    fileset = sourceFiles [ (root + "/rel") ];
  };
  version = "4.0.0";
  runtimePath = lib.makeBinPath [
    pkgs.curl
    pkgs.ffmpeg-full
    pkgs.yt-dlp
  ];
  testSrc = lib.fileset.toSource {
    inherit root;
    fileset = sourceFiles [ (root + "/test") ];
  };
in
rec {
  lolek = mixRelease {
    pname = "lolek";
    inherit version;
    inherit elixir src;

    mixFodDeps = fetchMixDeps {
      pname = "lolek-mix-deps";
      inherit version;
      src = root;
      inherit elixir;
      hash = "sha256-Qjtga/MGHD7lHylMNtGD343G4YHLxHPLnJGIt4/W6ow=";
    };
    doCheck = true;
    checkPhase = ''
      runHook preCheck

      export MIX_ENV="prod"
      export MIX_HOME="$TMPDIR/mix"
      export HEX_HOME="$TMPDIR/hex"
      export MIX_DEPS_PATH="$TMPDIR/deps"
      export REBAR_GLOBAL_CONFIG_DIR="$TMPDIR/rebar3"
      export REBAR_CACHE_DIR="$TMPDIR/rebar3.cache"

      cp -R ${testSrc}/test test
      mix test

      runHook postCheck
    '';
    doInstallCheck = true;
    nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
    versionCheckProgram = "${placeholder "out"}/bin/lolek";
    versionCheckProgramArg = "version";

    postInstall = ''
      cat >> "$out/releases/${version}/env.sh" <<'EOF'

      export RELEASE_COOKIE="''${RELEASE_COOKIE:-lolek}"
      export RELEASE_PROG="lolek"
      export PATH="${runtimePath}:$PATH"
      EOF
    '';

    meta = {
      description = "Telegram bot that downloads media from URLs and uploads it to Telegram";
      homepage = "https://github.com/skaborik/lolek_bot";
      license = lib.licenses.mit;
      mainProgram = "lolek";
      platforms = systems;
    };
  };

  default = lolek;
}
