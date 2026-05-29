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
          module = self.nixosModules.default;
          package = self.packages.${system}.lolek;
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
