{
  pkgs,
  root,
  corpus,
  module ? null,
  package ? null,
  telegym ? null,
  testCases ? null,
}:

let
  lib = pkgs.lib;
  mixBuilders = import ./pkgs/mix-builders.nix { inherit pkgs; };
  inherit (mixBuilders) fetchMixDeps mixRelease;
  version = "5.2.2";
  checkSrc = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.gitTracked root;
  };
  mixCheckDeps = fetchMixDeps {
    pname = "lolek-mix-check-deps";
    inherit version;
    src = root;
    mixEnv = "dev";
    hash = "sha256-NckDnRTaNZufkNOdrF9KRFuZE1mEr5s2UpCMyvltXU0=";
  };
in
{
  mix-check = mixRelease {
    pname = "lolek-mix-check";
    inherit version;
    src = checkSrc;
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
      # mix_audit fetches its advisory database at runtime.
      mix check --except mix_audit

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      touch "$out"

      runHook postInstall
    '';
  };

  python-typecheck =
    pkgs.runCommand "lolek-python-typecheck"
      {
        nativeBuildInputs = [
          corpus
          pkgs.ty
        ];
      }
      ''
        cd ${checkSrc}/corpus
        ty check src tests
        touch "$out"
      '';

  python-lint =
    pkgs.runCommand "lolek-python-lint"
      {
        nativeBuildInputs = [ pkgs.ruff ];
      }
      ''
        cd ${checkSrc}
        # checkSrc is a read-only Nix store path, so Ruff cannot create its
        # usual .ruff_cache directory alongside the sources.
        ruff format --check --no-cache .
        ruff check --no-cache .
        touch "$out"
      '';
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  nixos-module-url-allowlist = import ./tests/module-url-allowlist.nix {
    inherit pkgs module package;
  };

  nixos-service = import ./tests/service.nix {
    inherit
      pkgs
      module
      package
      telegym
      ;
  };

  nixos-tiktok-audio-mux = import ./tests/tiktok-audio-mux.nix {
    inherit
      pkgs
      module
      package
      telegym
      ;
  };

  nixos-concurrency = import ./tests/concurrency.nix {
    inherit
      pkgs
      module
      package
      telegym
      ;
  };

  nixos-deadline = import ./tests/deadline.nix {
    inherit
      pkgs
      module
      package
      telegym
      ;
  };

  nixos-corpus = import ./tests/corpus.nix {
    inherit
      pkgs
      module
      package
      telegym
      testCases
      ;
  };
}
