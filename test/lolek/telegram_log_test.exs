defmodule Lolek.TelegramLogTest do
  use ExUnit.Case, async: true

  test "redacts Telegram bot token path segments" do
    url = "https://api.telegram.org/bot123456:secret/getMe"

    assert Lolek.TelegramLog.sanitize_url(url) ==
             "https://api.telegram.org/bot[REDACTED]/getMe"
  end

  test "redacts Telegram file bot token path segments" do
    url = "https://api.telegram.org/file/bot123456:secret/videos/file.mp4"

    assert Lolek.TelegramLog.sanitize_url(url) ==
             "https://api.telegram.org/file/bot[REDACTED]/videos/file.mp4"
  end

  test "drops query strings and fragments from logged urls" do
    url = "http://127.0.0.1:8080/bot123456:secret/sendVideo?chat_id=1#fragment"

    assert Lolek.TelegramLog.sanitize_url(url) ==
             "http://127.0.0.1:8080/bot[REDACTED]/sendVideo"
  end

  test "formats successful request logs without leaking bot token" do
    request = %Tesla.Env{method: :post, url: "https://api.telegram.org/bot123456:secret/getMe"}
    response = {:ok, %Tesla.Env{status: 200}}

    formatted =
      request
      |> Lolek.TelegramLog.format_request(response, 12_345)
      |> IO.iodata_to_binary()

    assert formatted == "POST https://api.telegram.org/bot[REDACTED]/getMe -> 200 (12.345 ms)"
    refute formatted =~ "123456:secret"
  end

  test "downgrades successful getUpdates request logs to debug" do
    response = {:ok, %Tesla.Env{status: 200, url: "https://api.telegram.org/bot123456:secret/getUpdates"}}

    assert Lolek.TelegramLog.tesla_log_level(response) == :debug
  end

  test "keeps successful non-polling request logs at info" do
    response = {:ok, %Tesla.Env{status: 200, url: "https://api.telegram.org/bot123456:secret/sendVideo"}}

    assert Lolek.TelegramLog.tesla_log_level(response) == :info
  end

  test "leaves unsuccessful Tesla request log levels unchanged" do
    assert Lolek.TelegramLog.tesla_log_level({:ok, %Tesla.Env{status: 500}}) == :default
    assert Lolek.TelegramLog.tesla_log_level({:error, :timeout}) == :default
  end
end
