{ self }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.lolek;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    types
    ;
in
{
  options.services.lolek = {
    enable = mkEnableOption "Lolek Telegram media downloader bot";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.lolek;
      defaultText = lib.literalExpression "self.packages.\${pkgs.stdenv.hostPlatform.system}.lolek";
      description = "Lolek package to run.";
    };

    user = mkOption {
      type = types.str;
      default = "lolek";
      description = "User account under which Lolek runs.";
    };

    group = mkOption {
      type = types.str;
      default = "lolek";
      description = "Group under which Lolek runs.";
    };

    createUser = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to create the configured Lolek user and group.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/lolek";
      description = "State directory for Lolek.";
    };

    downloadDir = mkOption {
      type = types.path;
      default = "${cfg.stateDir}/downloads";
      defaultText = lib.literalExpression ''"''${config.services.lolek.stateDir}/downloads"'';
      description = "Directory where Lolek stores downloaded media.";
    };

    botTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a file containing the Telegram bot token. This is suitable for
        sops-nix secret paths. When set, the module exports
        LOLEK_BOT_TOKEN_FILE and Lolek reads the token from that file.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Optional environment file containing secrets such as LOLEK_BOT_TOKEN.";
    };

    environment = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.str
          types.int
          types.bool
        ]
      );
      default = { };
      description = "Additional environment variables for the Lolek service.";
    };
  };

  config = mkIf cfg.enable {
    users.groups = mkIf cfg.createUser {
      ${cfg.group} = { };
    };

    users.users = mkIf cfg.createUser {
      ${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.stateDir;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.downloadDir} 0750 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.lolek = {
      description = "Lolek Telegram media downloader bot";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        LOLEK_TELEGRAM_BASE_URL = "https://api.telegram.org";
        LOLEK_DOWNLOAD_DIR_PATH = toString cfg.downloadDir;
        LOLEK_MAX_DOWNLOAD_DIR_SIZE = "5368709120";
        LOLEK_MAX_FILE_SIZE_TO_SEND_TO_TELEGRAM = "45000000";
        LOLEK_MAX_VIDEO_SIZE_TO_SEND_TO_TELEGRAM = "40000000";
        LOLEK_MAX_AUDIO_SIZE_TO_SEND_TO_TELEGRAM = "5000000";
        LOLEK_MAX_FILE_SIZE_TO_COMPRESS = "100000000";
        LOLEK_MAX_DURATION_TO_COMPRESS = "300";
        LOLEK_ALLOWED_URLS_REGEX = "tiktok\\.com|twitter\\.com|facebook\\.com|instagram\\.com|threads\\.com|threads\\.net|coub\\.com|x\\.com|youtube\\.com\\/shorts";
        LOLEK_MAX_DOWNLOAD_TRIES = "10";
        LOLEK_START_DOWNLOAD_PAUSE = "1000";
        LOLEK_MAX_DOWNLOAD_PAUSE = "10000";
      }
      // optionalAttrs (cfg.botTokenFile != null) {
        LOLEK_BOT_TOKEN_FILE = toString cfg.botTokenFile;
      }
      // builtins.mapAttrs (_: toString) cfg.environment;

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/lolek start";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        Restart = "on-failure";
        ReadWritePaths = [
          cfg.stateDir
          cfg.downloadDir
        ];
      }
      // optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };
  };
}
