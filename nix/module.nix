{ self }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.lolek;
  defaultAllowedUrlPatterns = [
    "tiktok.com"
    "twitter.com"
    "facebook.com"
    "instagram.com"
    "threads.com"
    "threads.net"
    "coub.com"
    "x.com"
    "youtube.com/shorts"
  ];
  inherit (lib)
    getExe
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optionalAttrs
    types
    ;
  hardwareAccelerationEnabled = cfg.hardwareAcceleration.backend != "none";
  localTelegramBotApi = cfg.localTelegramBotApi;
  localTelegramBotApiServiceName = "lolek-telegram-bot-api";
  localTelegramBotApiBaseUrl = "http://${localTelegramBotApi.ipAddress}:${toString localTelegramBotApi.port}";
  effectiveTelegramBaseUrl =
    if localTelegramBotApi.enable then localTelegramBotApiBaseUrl else cfg.telegramBaseUrl;
  effectiveTelegramLocalFileUploads = cfg.telegramLocalFileUploads || localTelegramBotApi.enable;
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

    telegramBaseUrl = mkOption {
      type = types.str;
      default = "https://api.telegram.org";
      description = "Base URL of the Telegram Bot API server.";
    };

    telegramLocalFileUploads = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to send new media uploads as file:// URIs. This requires a
        local Telegram Bot API server running in local mode and able to read
        Lolek's download directory.
      '';
    };

    postSourceCaption = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to include cached source post text in Telegram media captions.
        Lolek still fetches and caches source text when this is disabled.
      '';
    };

    localTelegramBotApi = {
      enable = mkEnableOption "a local Telegram Bot API server sidecar";

      package = mkOption {
        type = types.package;
        default = pkgs.telegram-bot-api;
        defaultText = lib.literalExpression "pkgs.telegram-bot-api";
        description = "Telegram Bot API server package to run.";
      };

      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Environment file containing TELEGRAM_API_ID and TELEGRAM_API_HASH
          for the local Telegram Bot API server.
        '';
      };

      ipAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "IP address on which the local Telegram Bot API server listens.";
      };

      port = mkOption {
        type = types.port;
        default = 8081;
        description = "TCP port on which the local Telegram Bot API server listens.";
      };

      stateDir = mkOption {
        type = types.path;
        default = "${cfg.stateDir}/telegram-bot-api";
        defaultText = lib.literalExpression ''"''${config.services.lolek.stateDir}/telegram-bot-api"'';
        description = "State directory for the local Telegram Bot API server.";
      };

      tempDir = mkOption {
        type = types.path;
        default = "${cfg.localTelegramBotApi.stateDir}/tmp";
        defaultText = lib.literalExpression ''
          "''${config.services.lolek.localTelegramBotApi.stateDir}/tmp"
        '';
        description = "Temporary upload directory for the local Telegram Bot API server.";
      };

      verbosity = mkOption {
        type = types.ints.unsigned;
        default = 2;
        description = "Telegram Bot API server log verbosity.";
      };
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional systemd environment file. This is an escape hatch for
        env-file formatted secrets and settings.
      '';
    };

    allowedUrlPatterns = mkOption {
      type = types.listOf (types.strMatching "[A-Za-z0-9._/-]+");
      default = defaultAllowedUrlPatterns;
      description = ''
        Host/path suffixes accepted by the bot. Subdomains of host-only entries
        are also accepted by the application. Query strings and fragments are
        ignored during matching.
      '';
    };

    maxDownloadDirSize = mkOption {
      type = types.ints.unsigned;
      default = 5368709120;
      description = "Maximum recursive size, in bytes, of the download cache.";
    };

    maxFileSizeToSendToTelegram = mkOption {
      type = types.ints.positive;
      default = 45000000;
      description = "Maximum final media size, in bytes, that Lolek sends to Telegram.";
    };

    maxVideoSizeToSendToTelegram = mkOption {
      type = types.ints.positive;
      default = 40000000;
      description = "Video byte budget used when calculating compression bitrate.";
    };

    maxAudioSizeToSendToTelegram = mkOption {
      type = types.ints.positive;
      default = 5000000;
      description = "Audio byte budget used when calculating compression bitrate.";
    };

    maxFileSizeToCompress = mkOption {
      type = types.ints.positive;
      default = 100000000;
      description = ''
        Maximum source media size, in bytes, eligible for compression. This also
        caps streamed Threads media downloads.
      '';
    };

    maxDurationToCompress = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Maximum video duration, in seconds, eligible for compression.";
    };

    maxConcurrentDownloads = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "Maximum number of downloads and conversions processed concurrently.";
    };

    maxConcurrentDownloadsPerChat = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Maximum number of downloads and conversions processed concurrently per chat.";
    };

    maxVideoRequestsPerChatPerMinute = mkOption {
      type = types.ints.positive;
      default = 10;
      description = "Maximum number of video URL requests admitted per chat per rolling minute.";
    };

    downloadCommandTimeout = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Timeout, in seconds, for yt-dlp and Threads curl commands.";
    };

    convertCommandTimeout = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Timeout, in seconds, for ffmpeg conversion commands.";
    };

    probeCommandTimeout = mkOption {
      type = types.ints.positive;
      default = 15;
      description = "Timeout, in seconds, for ffprobe metadata commands.";
    };

    hardwareAcceleration = {
      backend = mkOption {
        type = types.enum [
          "none"
          "vaapi"
          "qsv"
        ];
        default = "none";
        description = ''
          Hardware acceleration backend for H.264 encoding. The default keeps
          software libx264 encoding. The vaapi backend uses h264_vaapi, while
          qsv uses h264_qsv.
        '';
      };

      device = mkOption {
        type = types.path;
        default = "/dev/dri/renderD128";
        description = "Render device used when hardware acceleration is enabled.";
      };
    };

    maxDownloadTries = mkOption {
      type = types.ints.positive;
      default = 10;
      description = "Total number of attempts for a download.";
    };

    startDownloadPause = mkOption {
      type = types.ints.unsigned;
      default = 1000;
      description = "Initial delay, in milliseconds, before retrying a failed download.";
    };

    maxDownloadPause = mkOption {
      type = types.ints.unsigned;
      default = 10000;
      description = "Maximum retry delay, in milliseconds, for failed downloads.";
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
    assertions = [
      {
        assertion = cfg.allowedUrlPatterns != [ ];
        message = "services.lolek.allowedUrlPatterns must not be empty.";
      }
      {
        assertion =
          cfg.maxVideoSizeToSendToTelegram + cfg.maxAudioSizeToSendToTelegram
          <= cfg.maxFileSizeToSendToTelegram;
        message = ''
          services.lolek.maxVideoSizeToSendToTelegram plus
          services.lolek.maxAudioSizeToSendToTelegram must be less than or
          equal to services.lolek.maxFileSizeToSendToTelegram.
        '';
      }
      {
        assertion = cfg.maxFileSizeToCompress >= cfg.maxFileSizeToSendToTelegram;
        message = ''
          services.lolek.maxFileSizeToCompress must be greater than or equal to
          services.lolek.maxFileSizeToSendToTelegram.
        '';
      }
      {
        assertion = cfg.startDownloadPause <= cfg.maxDownloadPause;
        message = ''
          services.lolek.startDownloadPause must be less than or equal to
          services.lolek.maxDownloadPause.
        '';
      }
      {
        assertion = cfg.maxConcurrentDownloadsPerChat <= cfg.maxConcurrentDownloads;
        message = ''
          services.lolek.maxConcurrentDownloadsPerChat must be less than or
          equal to services.lolek.maxConcurrentDownloads.
        '';
      }
      {
        assertion =
          !effectiveTelegramLocalFileUploads || effectiveTelegramBaseUrl != "https://api.telegram.org";
        message = ''
          services.lolek.telegramLocalFileUploads requires
          services.lolek.telegramBaseUrl to point at a local Telegram Bot API
          server.
        '';
      }
      {
        assertion = !localTelegramBotApi.enable || localTelegramBotApi.environmentFile != null;
        message = ''
          services.lolek.localTelegramBotApi.environmentFile must be set when
          services.lolek.localTelegramBotApi.enable is true.
        '';
      }
    ];

    users.groups = mkMerge [
      (mkIf cfg.createUser {
        ${cfg.group} = { };
      })
      (mkIf hardwareAccelerationEnabled {
        render = { };
        video = { };
      })
    ];

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
    ]
    ++ lib.optionals localTelegramBotApi.enable [
      "d ${localTelegramBotApi.stateDir} 0750 ${cfg.user} ${cfg.group} - -"
      "d ${localTelegramBotApi.tempDir} 0750 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.${localTelegramBotApiServiceName} = mkIf localTelegramBotApi.enable {
      description = "Local Telegram Bot API server for Lolek";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = "${getExe localTelegramBotApi.package} --local --http-ip-address=${localTelegramBotApi.ipAddress} --http-port=${toString localTelegramBotApi.port} --dir=${localTelegramBotApi.stateDir} --temp-dir=${localTelegramBotApi.tempDir} --verbosity=${toString localTelegramBotApi.verbosity}";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = localTelegramBotApi.stateDir;
        Restart = "on-failure";
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          localTelegramBotApi.stateDir
          localTelegramBotApi.tempDir
        ];
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        UMask = "0077";
      }
      // optionalAttrs (localTelegramBotApi.environmentFile != null) {
        EnvironmentFile = localTelegramBotApi.environmentFile;
      };
    };

    systemd.services.lolek = {
      description = "Lolek Telegram media downloader bot";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optionals localTelegramBotApi.enable [ "${localTelegramBotApiServiceName}.service" ];
      wants = [
        "network-online.target"
      ]
      ++ lib.optionals localTelegramBotApi.enable [ "${localTelegramBotApiServiceName}.service" ];

      environment = {
        LOLEK_TELEGRAM_BASE_URL = effectiveTelegramBaseUrl;
        LOLEK_TELEGRAM_LOCAL_FILE_UPLOADS = if effectiveTelegramLocalFileUploads then "true" else "false";
        LOLEK_POST_SOURCE_CAPTION = if cfg.postSourceCaption then "true" else "false";
        LOLEK_DOWNLOAD_DIR_PATH = toString cfg.downloadDir;
        LOLEK_MAX_DOWNLOAD_DIR_SIZE = toString cfg.maxDownloadDirSize;
        LOLEK_MAX_FILE_SIZE_TO_SEND_TO_TELEGRAM = toString cfg.maxFileSizeToSendToTelegram;
        LOLEK_MAX_VIDEO_SIZE_TO_SEND_TO_TELEGRAM = toString cfg.maxVideoSizeToSendToTelegram;
        LOLEK_MAX_AUDIO_SIZE_TO_SEND_TO_TELEGRAM = toString cfg.maxAudioSizeToSendToTelegram;
        LOLEK_MAX_FILE_SIZE_TO_COMPRESS = toString cfg.maxFileSizeToCompress;
        LOLEK_MAX_DURATION_TO_COMPRESS = toString cfg.maxDurationToCompress;
        LOLEK_MAX_CONCURRENT_DOWNLOADS = toString cfg.maxConcurrentDownloads;
        LOLEK_MAX_CONCURRENT_DOWNLOADS_PER_CHAT = toString cfg.maxConcurrentDownloadsPerChat;
        LOLEK_MAX_VIDEO_REQUESTS_PER_CHAT_PER_MINUTE = toString cfg.maxVideoRequestsPerChatPerMinute;
        LOLEK_DOWNLOAD_COMMAND_TIMEOUT_SECONDS = toString cfg.downloadCommandTimeout;
        LOLEK_CONVERT_COMMAND_TIMEOUT_SECONDS = toString cfg.convertCommandTimeout;
        LOLEK_PROBE_COMMAND_TIMEOUT_SECONDS = toString cfg.probeCommandTimeout;
        LOLEK_HW_ACCELERATION = cfg.hardwareAcceleration.backend;
        LOLEK_HW_DEVICE = toString cfg.hardwareAcceleration.device;
        LOLEK_ALLOWED_URLS_REGEX = lib.concatStringsSep "|" (map lib.escapeRegex cfg.allowedUrlPatterns);
        LOLEK_MAX_DOWNLOAD_TRIES = toString cfg.maxDownloadTries;
        LOLEK_START_DOWNLOAD_PAUSE = toString cfg.startDownloadPause;
        LOLEK_MAX_DOWNLOAD_PAUSE = toString cfg.maxDownloadPause;
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
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = !hardwareAccelerationEnabled;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.stateDir
          cfg.downloadDir
        ];
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        UMask = "0077";
      }
      // optionalAttrs hardwareAccelerationEnabled {
        SupplementaryGroups = [
          "render"
          "video"
        ];
      }
      // optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };
  };
}
