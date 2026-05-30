{
  pkgs,
  root,
  module ? null,
  package ? null,
}:

{
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  nixos-service = import ./tests/service.nix {
    inherit pkgs module package;
  };

  nixos-concurrency = import ./tests/concurrency.nix {
    inherit pkgs module package;
  };
}
