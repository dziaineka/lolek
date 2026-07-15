defmodule LolekTest do
  use ExUnit.Case
  doctest Lolek

  setup do
    max_message_delay_seconds = Application.get_env(:lolek, :max_message_delay_seconds)
    allowed_urls_regex = Application.get_env(:lolek, :allowed_urls_regex)

    Application.put_env(:lolek, :max_message_delay_seconds, 300)
    Application.put_env(:lolek, :allowed_urls_regex, "tiktok\\.com")

    on_exit(fn ->
      restore_app_env(:max_message_delay_seconds, max_message_delay_seconds)
      restore_app_env(:allowed_urls_regex, allowed_urls_regex)
    end)
  end

  test "drops text messages delayed beyond the configured maximum" do
    message = text_message("https://tiktok.com/video", System.system_time(:second) - 301)

    assert :ok = Lolek.Handler.handle({:text, message.text, message}, %ExGram.Cnt{})
  end

  test "drops text messages when the overall deadline has elapsed" do
    message = text_message("https://tiktok.com/video", System.system_time(:second) - 300)

    assert :ok = Lolek.Handler.handle({:text, message.text, message}, %ExGram.Cnt{})
  end

  test "drops start commands delayed beyond the configured maximum" do
    message = text_message("/start", System.system_time(:second) - 301)

    assert :ok = Lolek.Handler.handle({:command, :start, message}, %ExGram.Cnt{})
  end

  defp text_message(text, date) do
    %ExGram.Model.Message{
      message_id: 1,
      date: date,
      text: text,
      chat: %ExGram.Model.Chat{id: 123, type: "private"},
      from: %ExGram.Model.User{id: 123, is_bot: false, first_name: "Alice"}
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:lolek, key)
  defp restore_app_env(key, value), do: Application.put_env(:lolek, key, value)
end
