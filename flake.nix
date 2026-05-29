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
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (
        system:
        import ./nix/package.nix {
          pkgs = pkgsFor system;
          root = ./.;
          inherit systems;
        }
      );

      checks = forAllSystems (
        system:
        import ./nix/checks.nix {
          pkgs = pkgsFor system;
          root = ./.;
        }
      );

      formatter = forAllSystems (
        system:
        import ./nix/formatter.nix {
          pkgs = pkgsFor system;
        }
      );
    };
}
