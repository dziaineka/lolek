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
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;
          beamPackages = pkgs.beam.packages.erlang_28;
          mixRelease = beamPackages.mixRelease.override {
            rebar3 = beamPackages.rebar3WithPlugins {
              globalPlugins = [ beamPackages.pc ];
            };
          };

          runtimePath = lib.makeBinPath [
            pkgs.curl
            pkgs.ffmpeg
            pkgs.yt-dlp
          ];
        in
        {
          lolek = mixRelease {
            pname = "lolek";
            version = "1.8.1";
            elixir = beamPackages.elixir_1_19;

            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./config
                ./lib
                ./mix.exs
                ./mix.lock
                ./rel
              ];
            };

            mixFodDeps = beamPackages.fetchMixDeps {
              pname = "lolek-mix-deps";
              version = "1.8.1";
              src = ./.;
              hash = "sha256-pdh+PiriuRixsEw2Mvjop3kTRyUo60mWdcB3PWhkqK8=";
            };

            nativeBuildInputs = [ pkgs.makeWrapper ];

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
    };
}
