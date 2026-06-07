import Config

parse_bool = fn var, default ->
  case System.get_env(var, default) do
    "true" -> true
    "false" -> false
    other -> raise "Config #{var} must be \"true\" or \"false\", got: #{inspect(other)}"
  end
end

parse_pos_int = fn var, default ->
  raw = System.get_env(var, default)

  case Integer.parse(raw) do
    {n, ""} when n > 0 -> n
    _ -> raise "Config #{var} must be a positive integer, got: #{inspect(raw)}"
  end
end

parse_non_neg_int = fn var, default ->
  raw = System.get_env(var, default)

  case Integer.parse(raw) do
    {n, ""} when n >= 0 -> n
    _ -> raise "Config #{var} must be a non-negative integer, got: #{inspect(raw)}"
  end
end

bot_token =
  case System.get_env("LOLEK_BOT_TOKEN_FILE") do
    path when path in [nil, ""] ->
      if config_env() == :test do
        System.get_env("LOLEK_BOT_TOKEN", "test_token")
      else
        System.fetch_env!("LOLEK_BOT_TOKEN")
      end

    path ->
      path |> File.read!() |> String.trim()
  end

telegram_base_url = System.get_env("LOLEK_TELEGRAM_BASE_URL", "https://api.telegram.org")
metrics_listen_address = System.get_env("LOLEK_METRICS_LISTEN_ADDRESS", "127.0.0.1")
hw_acceleration = System.get_env("LOLEK_HW_ACCELERATION", "none")
hw_device = System.get_env("LOLEK_HW_DEVICE", "/dev/dri/renderD128")

allowed_urls_regex =
  System.get_env(
    "LOLEK_ALLOWED_URLS_REGEX",
    "tiktok\\.com|twitter\\.com|facebook\\.com|instagram\\.com|threads\\.com|threads\\.net|coub\\.com|x\\.com|youtube\\.com\\/shorts"
  )

download_path = System.get_env("LOLEK_DOWNLOAD_DIR_PATH", "./downloads")

telegram_local_file_uploads = parse_bool.("LOLEK_TELEGRAM_LOCAL_FILE_UPLOADS", "false")
metrics_enabled = parse_bool.("LOLEK_METRICS_ENABLED", "false")
post_source_caption = parse_bool.("LOLEK_POST_SOURCE_CAPTION", "false")
post_requester_caption = parse_bool.("LOLEK_POST_REQUESTER_CAPTION", "false")

metrics_port = parse_pos_int.("LOLEK_METRICS_PORT", "9568")
max_download_dir_size = parse_non_neg_int.("LOLEK_MAX_DOWNLOAD_DIR_SIZE", "5368709120")

max_file_size_to_send_to_telegram =
  parse_pos_int.("LOLEK_MAX_FILE_SIZE_TO_SEND_TO_TELEGRAM", "45000000")

max_video_size_to_send_to_telegram =
  parse_pos_int.("LOLEK_MAX_VIDEO_SIZE_TO_SEND_TO_TELEGRAM", "40000000")

max_audio_size_to_send_to_telegram =
  parse_pos_int.("LOLEK_MAX_AUDIO_SIZE_TO_SEND_TO_TELEGRAM", "5000000")

max_file_size_to_compress = parse_pos_int.("LOLEK_MAX_FILE_SIZE_TO_COMPRESS", "100000000")
max_duration_to_compress = parse_pos_int.("LOLEK_MAX_DURATION_TO_COMPRESS", "300")
max_concurrent_downloads = parse_pos_int.("LOLEK_MAX_CONCURRENT_DOWNLOADS", "2")
max_concurrent_downloads_per_chat = parse_pos_int.("LOLEK_MAX_CONCURRENT_DOWNLOADS_PER_CHAT", "1")

max_video_requests_per_chat_per_minute =
  parse_pos_int.("LOLEK_MAX_VIDEO_REQUESTS_PER_CHAT_PER_MINUTE", "10")

download_command_timeout_seconds = parse_pos_int.("LOLEK_DOWNLOAD_COMMAND_TIMEOUT_SECONDS", "300")
convert_command_timeout_seconds = parse_pos_int.("LOLEK_CONVERT_COMMAND_TIMEOUT_SECONDS", "300")
probe_command_timeout_seconds = parse_pos_int.("LOLEK_PROBE_COMMAND_TIMEOUT_SECONDS", "15")
max_download_tries = parse_pos_int.("LOLEK_MAX_DOWNLOAD_TRIES", "10")
start_download_pause = parse_pos_int.("LOLEK_START_DOWNLOAD_PAUSE", "1000")
max_download_pause = parse_pos_int.("LOLEK_MAX_DOWNLOAD_PAUSE", "10000")

unless hw_acceleration in ["none", "vaapi", "qsv"] do
  raise "Config LOLEK_HW_ACCELERATION must be one of \"none\", \"vaapi\", \"qsv\", got: #{inspect(hw_acceleration)}"
end

unless start_download_pause <= max_download_pause do
  raise "Config LOLEK_START_DOWNLOAD_PAUSE (#{start_download_pause}) must be <= LOLEK_MAX_DOWNLOAD_PAUSE (#{max_download_pause})"
end

unless max_concurrent_downloads_per_chat <= max_concurrent_downloads do
  raise "Config LOLEK_MAX_CONCURRENT_DOWNLOADS_PER_CHAT (#{max_concurrent_downloads_per_chat}) must be <= LOLEK_MAX_CONCURRENT_DOWNLOADS (#{max_concurrent_downloads})"
end

config :logger, level: :info

config :ex_gram,
  token: bot_token,
  base_url: telegram_base_url

config :ex_gram, Tesla.Middleware.Logger,
  format: {Lolek.TelegramLog, :format_request},
  level: &Lolek.TelegramLog.tesla_log_level/1,
  debug: false

config :lolek, :bot_token, bot_token
config :lolek, :telegram_local_file_uploads, telegram_local_file_uploads
config :lolek, :metrics_enabled, metrics_enabled
config :lolek, :metrics_listen_address, metrics_listen_address
config :lolek, :metrics_port, metrics_port
config :lolek, :post_source_caption, post_source_caption
config :lolek, :post_requester_caption, post_requester_caption
config :lolek, :download_path, download_path
config :lolek, :max_download_dir_size, max_download_dir_size
config :lolek, :max_file_size_to_send_to_telegram, max_file_size_to_send_to_telegram
config :lolek, :max_video_size_to_send_to_telegram, max_video_size_to_send_to_telegram
config :lolek, :max_audio_size_to_send_to_telegram, max_audio_size_to_send_to_telegram
config :lolek, :max_file_size_to_compress, max_file_size_to_compress
config :lolek, :max_duration_to_compress, max_duration_to_compress
config :lolek, :max_concurrent_downloads, max_concurrent_downloads
config :lolek, :max_concurrent_downloads_per_chat, max_concurrent_downloads_per_chat
config :lolek, :max_video_requests_per_chat_per_minute, max_video_requests_per_chat_per_minute
config :lolek, :download_command_timeout_seconds, download_command_timeout_seconds
config :lolek, :convert_command_timeout_seconds, convert_command_timeout_seconds
config :lolek, :probe_command_timeout_seconds, probe_command_timeout_seconds
config :lolek, :hw_acceleration, hw_acceleration
config :lolek, :hw_device, hw_device
config :lolek, :allowed_urls_regex, allowed_urls_regex
config :lolek, :max_download_tries, max_download_tries
config :lolek, :start_download_pause, start_download_pause
config :lolek, :max_download_pause, max_download_pause
