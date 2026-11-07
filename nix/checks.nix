{
  pkgs,
  root,
  corpus,
  module ? null,
  package ? null,
  telegym ? null,
  telegymModule ? null,
  testCases ? null,
}:

let
  lib = pkgs.lib;
  mixBuilders = import ./pkgs/mix-builders.nix { inherit pkgs; };
  inherit (mixBuilders) fetchMixDeps mixRelease;
  version = "5.4.1";
  checkSrc = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.gitTracked root;
  };
  mixCheckDeps = fetchMixDeps {
    pname = "lolek-mix-check-deps";
    inherit version;
    src = root;
    mixEnv = "dev";
    hash = "sha256-a2Vxinhb1Ca+hq+o7tQFHvblZghR23H3CB+y148czCk=";
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
      # These checks fetch data from Hex at runtime, but the Nix sandbox
      # has no network access.
      mix check --except hex_audit --except mix_audit

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
      telegymModule
      ;
  };

  nixos-tiktok-audio-mux = import ./tests/tiktok-audio-mux.nix {
    inherit
      pkgs
      module
      package
      telegym
      telegymModule
      ;
  };

  nixos-concurrency = import ./tests/concurrency.nix {
    inherit
      pkgs
      module
      package
      telegym
      telegymModule
      ;
  };

  nixos-deadline = import ./tests/deadline.nix {
    inherit
      pkgs
      module
      package
      telegym
      telegymModule
      ;
  };

  nixos-corpus = import ./tests/corpus.nix {
    inherit
      pkgs
      module
      package
      telegym
      telegymModule
      testCases
      ;
  };
}
