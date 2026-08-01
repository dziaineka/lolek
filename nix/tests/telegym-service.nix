{
  package,
  listenAddress ? "127.0.0.1",
  port ? 5678,
  fileStoreMaxBytes ? 100 * 1024 * 1024,
}:

{
  systemd.services.telegym-mock = {
    description = "Telegym Telegram Bot API mock";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    environment = {
      TELEGYM_MOCK_LISTEN = "${listenAddress}:${toString port}";
      TELEGYM_MOCK_METRICS_LISTEN = "";
      TELEGYM_MOCK_FILE_STORE_MAX_BYTES = toString fileStoreMaxBytes;
      TELEGYM_MOCK_QUIET = "true";
    };
    serviceConfig = {
      ExecStart = "${package}/bin/telegym-mock";
      Restart = "on-failure";
    };
  };
}
