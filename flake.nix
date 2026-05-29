{
  description = "Lolek Telegram media downloader bot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
      perSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;
          beamPackages = pkgs.beam.packages.erlang_28;
          elixir = beamPackages.elixir_1_19;
          rebar3WithPlugins = beamPackages.rebar3WithPlugins {
            globalPlugins = [ beamPackages.pc ];
          };
          fetchMixDeps = beamPackages.fetchMixDeps.override {
            rebar3 = rebar3WithPlugins;
          };
          mixRelease = beamPackages.mixRelease.override {
            rebar3 = rebar3WithPlugins;
          };
          sourceFiles =
            extraFiles:
            lib.fileset.unions (
              [
                ./config
                ./lib
                ./mix.exs
                ./mix.lock
              ]
              ++ extraFiles
            );
          src = lib.fileset.toSource {
            root = ./.;
            fileset = sourceFiles [ ./rel ];
          };
          testSrc = lib.fileset.toSource {
            root = ./.;
            fileset = sourceFiles [ ./test ];
          };
          runtimePath = lib.makeBinPath [
            pkgs.curl
            pkgs.ffmpeg
            pkgs.yt-dlp
          ];
        in
        {
          inherit
            pkgs
            lib
            beamPackages
            elixir
            rebar3WithPlugins
            fetchMixDeps
            mixRelease
            src
            testSrc
            runtimePath
            ;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          inherit (perSystem system)
            lib
            elixir
            fetchMixDeps
            mixRelease
            runtimePath
            src
            ;
        in
        {
          lolek = mixRelease {
            pname = "lolek";
            version = "1.8.1";
            inherit elixir;

            inherit src;

            mixFodDeps = fetchMixDeps {
              pname = "lolek-mix-deps";
              version = "1.8.1";
              src = ./.;
              inherit elixir;
              hash = "sha256-pdh+PiriuRixsEw2Mvjop3kTRyUo60mWdcB3PWhkqK8=";
            };

            postInstall = ''
              wrapProgram "$out/bin/lolek" \
                --run 'export RELEASE_COOKIE="''${RELEASE_COOKIE:-lolek}"' \
                --prefix PATH : ${runtimePath}
            '';

            meta = {
              description = "Telegram bot that downloads media from URLs and uploads it to Telegram";
              homepage = "https://github.com/skaborik/lolek_bot";
              license = lib.licenses.mit;
              mainProgram = "lolek";
              platforms = systems;
            };
          };

          default = self.packages.${system}.lolek;
        }
      );

      checks = forAllSystems (
        system:
        let
          inherit (perSystem system)
            pkgs
            beamPackages
            elixir
            rebar3WithPlugins
            fetchMixDeps
            testSrc
            ;
          testMixDeps = fetchMixDeps {
            pname = "lolek-test-mix-deps";
            version = "1.8.1";
            src = ./.;
            mixEnv = "test";
            inherit elixir;
            hash = "sha256-fiKeK0DCZZiwE0qhuD+BruI7PHkHPaxv9ivvfti1FYU=";
          };
        in
        {
          test = pkgs.stdenv.mkDerivation {
            pname = "lolek-test";
            version = "1.8.1";
            src = testSrc;

            nativeBuildInputs = [
              elixir
              (beamPackages.hex.override { inherit elixir; })
              beamPackages.rebar
              rebar3WithPlugins
            ];

            env = {
              MIX_ENV = "test";
              HEX_OFFLINE = 1;
              MIX_REBAR = "${beamPackages.rebar}/bin/rebar";
              MIX_REBAR3 = "${rebar3WithPlugins}/bin/rebar3";
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
      );

      formatter = forAllSystems (
        system:
        let
          inherit (perSystem system) pkgs;
        in
        pkgs.writeShellApplication {
          name = "formatter";
          runtimeInputs = [ pkgs.nixfmt-tree ];
          text = ''
            treefmt "$@"
          '';
        }
      );
    };
}
