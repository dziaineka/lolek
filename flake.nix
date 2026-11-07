{
  description = "Lolek Telegram media downloader bot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-26.05";
    telegym = {
      url = "github:booxter/telegym/lolek-missing-features";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      telegym,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              beam = prev.beam // {
                packages = prev.beam.packages // {
                  erlang_29 = prev.beam.packages.erlang_29 // {
                    elixir_1_20 = prev.beam.packages.erlang_29.elixir_1_20.overrideAttrs (_: {
                      version = "1.20.5";
                      src = prev.fetchFromGitHub {
                        owner = "elixir-lang";
                        repo = "elixir";
                        rev = "v1.20.5";
                        hash = "sha256-MsRNaWAQ05ysL3hOqpfhm//tRNL0Z4Ia/NfEWEQfEWE=";
                      };
                    });
                  };
                };
              };
              # Keep Nix builds on the versions pinned in .tool-versions.
              yt-dlp = prev.yt-dlp.overrideAttrs (_: {
                version = "2026.11.04.232659";
                src = prev.fetchzip {
                  url = "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/2026.11.04.232659/yt-dlp.tar.gz";
                  hash = "sha256-x7hh6K2j3BqFUJYuSdkX1MMspU6ud+6Vo8nXpd5WwPs=";
                };
              });
              gallery-dl = (prev.gallery-dl.override { yt-dlp = final.yt-dlp; }).overrideAttrs (_: {
                version = "1.32.19";
                src = prev.fetchFromCodeberg {
                  owner = "mikf";
                  repo = "gallery-dl";
                  tag = "v1.32.19";
                  hash = "sha256-iMC0KpgyYPqyHpYwYw9DFsvCMHUIwqqVP2Pfm1SviB0=";
                };
              });
            })
          ];
        };
    in
    {
      packages = forAllSystems (
        system:
        import ./nix/package.nix {
          pkgs = pkgsFor system;
          root = ./.;
          telegym = telegym.packages.${system}.telegym;
          inherit systems;
        }
      );

      checks = forAllSystems (
        system:
        import ./nix/checks.nix {
          pkgs = pkgsFor system;
          root = ./.;
          module = self.nixosModules.default;
          package = self.packages.${system}.lolek;
          corpus = self.packages.${system}.corpus;
          telegym = telegym.packages.${system}.telegym;
          telegymModule = telegym.nixosModules.default;
          testCases = self.packages.${system}.get-test-cases;
        }
      );

      apps = forAllSystems (
        system:
        let
          mkApp = name: description: {
            type = "app";
            program = nixpkgs.lib.getExe self.packages.${system}.${name};
            meta = { inherit description; };
          };
        in
        {
          get-test-cases = mkApp "get-test-cases" "List upstream extractor test cases";
          live-corpus = mkApp "live-corpus" "Test Lolek through live media services";
          live-corpus-check = mkApp "live-corpus-check" "Detect live yt-dlp regressions";
          live-corpus-gallery = mkApp "live-corpus-gallery" "Test live gallery-dl media";
          live-corpus-gallery-check = mkApp "live-corpus-gallery-check" "Detect live gallery-dl regressions";
        }
      );

      formatter = forAllSystems (
        system:
        import ./nix/formatter.nix {
          pkgs = pkgsFor system;
        }
      );

      nixosModules.default = import ./nix/module.nix { inherit self; };
    };
}
