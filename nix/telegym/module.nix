# NixOS service for the Telegym mock, used by the NixOS integration tests.
{ package }:

{
  config,
  lib,
  ...
}:

let
  cfg = config.services.telegym-mock;
in
{
  options.services.telegym-mock = {
    enable = lib.mkEnableOption "Telegym Telegram Bot API mock";

    package = lib.mkOption {
      type = lib.types.package;
      default = package;
      defaultText = lib.literalExpression "lolek.packages.\${system}.telegym";
      description = "Telegym package to use.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address on which the mock Bot API listens.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5678;
      description = "Port on which the mock Bot API listens.";
    };

    fileStoreMaxBytes = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 100 * 1024 * 1024;
      description = "Maximum number of uploaded file bytes retained in memory.";
    };

    quiet = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to suppress per-request logs.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.telegym-mock = {
      description = "Telegym Telegram Bot API mock";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        TELEGYM_MOCK_LISTEN = "${cfg.listenAddress}:${toString cfg.port}";
        TELEGYM_MOCK_METRICS_LISTEN = "";
        TELEGYM_MOCK_FILE_STORE_MAX_BYTES = toString cfg.fileStoreMaxBytes;
        TELEGYM_MOCK_QUIET = lib.boolToString cfg.quiet;
      };
      serviceConfig = {
        ExecStart = lib.getExe' cfg.package "telegym-mock";
        Restart = "on-failure";
      };
    };
  };
}
