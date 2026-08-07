{
  description = "Lolek Telegram media downloader bot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-26.05";
    telegym = {
      url = "github:booxter/telegym/lolek-missing-features";
      flake = false;
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
                      version = "1.20.2";
                      src = prev.fetchFromGitHub {
                        owner = "elixir-lang";
                        repo = "elixir";
                        rev = "v1.20.2";
                        hash = "sha256-KSRsXQhh3PX7SUNhuw/POg74XfjkPiZDsv9wdNwFrwA=";
                      };
                    });
                  };
                };
              };
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
          telegymSrc = telegym;
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
          telegym = self.packages.${system}.telegym;
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
