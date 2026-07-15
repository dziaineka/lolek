{
  pkgs,
  module,
  package,
}:

let
  defaultConfiguration = pkgs.nixos [
    module
    {
      services.lolek = {
        enable = true;
        inherit package;
      };
      system.stateVersion = "26.05";
    }
  ];
  overriddenConfiguration = pkgs.nixos [
    module
    {
      services.lolek = {
        enable = true;
        inherit package;
        allowedUrlPatterns = [ "example.com/video" ];
      };
      system.stateVersion = "26.05";
    }
  ];
  defaultEnvironment = defaultConfiguration.config.systemd.services.lolek.environment;
  overriddenEnvironment = overriddenConfiguration.config.systemd.services.lolek.environment;
in
assert !(defaultEnvironment ? LOLEK_ALLOWED_URLS_REGEX);
assert overriddenEnvironment ? LOLEK_ALLOWED_URLS_REGEX;
pkgs.runCommand "lolek-nixos-module-url-allowlist-check" { } ''
  touch "$out"
''
