{
  pkgs,
  root,
}:

let
  common = import ./common.nix { inherit pkgs root; };

  testMixDeps = common.fetchMixDeps {
    pname = "lolek-test-mix-deps";
    version = "1.8.1";
    src = root;
    mixEnv = "test";
    inherit (common) elixir;
    hash = "sha256-fiKeK0DCZZiwE0qhuD+BruI7PHkHPaxv9ivvfti1FYU=";
  };
in
{
  test = pkgs.stdenv.mkDerivation {
    pname = "lolek-test";
    version = "1.8.1";
    src = common.testSrc;

    nativeBuildInputs = [
      common.elixir
      (common.beamPackages.hex.override { inherit (common) elixir; })
      common.beamPackages.rebar
      common.rebar3WithPlugins
    ];

    env = {
      MIX_ENV = "test";
      HEX_OFFLINE = 1;
      MIX_REBAR = "${common.beamPackages.rebar}/bin/rebar";
      MIX_REBAR3 = "${common.rebar3WithPlugins}/bin/rebar3";
      LANG = if pkgs.stdenv.hostPlatform.isLinux then "C.UTF-8" else "C";
      LC_CTYPE = if pkgs.stdenv.hostPlatform.isLinux then "C.UTF-8" else "UTF-8";
    };

    configurePhase = ''
      runHook preConfigure

      export MIX_HOME="$TMPDIR/mix"
      export HEX_HOME="$TMPDIR/hex"
      export MIX_DEPS_PATH="$TMPDIR/deps"
      export REBAR_GLOBAL_CONFIG_DIR="$TMPDIR/rebar3"
      export REBAR_CACHE_DIR="$TMPDIR/rebar3.cache"

      cp --no-preserve=mode -R "${testMixDeps}" "$MIX_DEPS_PATH"

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      mix test
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      touch "$out/passed"
      runHook postInstall
    '';
  };
}
