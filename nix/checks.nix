{
  pkgs,
  root,
  module ? null,
  package ? null,
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
  version = "5.1.1";
  mixCheckSrc = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.gitTracked root;
  };
  mixCheckDeps = fetchMixDeps {
    pname = "lolek-mix-check-deps";
    inherit version elixir;
    src = root;
    mixEnv = "dev";
    hash = "sha256-0S2HHMQz3JBJx2xdHf1+yqqXXZOkATzJWjg2Q9LupDc=";
  };
in
{
  mix-check = mixRelease {
    pname = "lolek-mix-check";
    inherit version elixir;
    src = mixCheckSrc;
    mixEnv = "dev";
    mixFodDeps = mixCheckDeps;
    erlangDeterministicBuilds = false;
    nativeBuildInputs = [
      pkgs.getconf
      pkgs.writableTmpDirAsHomeHook
    ];

    buildPhase = ''
      runHook preBuild

      export LOLEK_BOT_TOKEN="test_token"
      mix check

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      touch "$out"

      runHook postInstall
    '';
  };
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  nixos-module-url-allowlist = import ./tests/module-url-allowlist.nix {
    inherit pkgs module package;
  };

  nixos-service = import ./tests/service.nix {
    inherit pkgs module package;
  };

  nixos-tiktok-audio-mux = import ./tests/tiktok-audio-mux.nix {
    inherit pkgs module package;
  };

  nixos-concurrency = import ./tests/concurrency.nix {
    inherit pkgs module package;
  };
}
