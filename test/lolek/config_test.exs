defmodule Lolek.ConfigTest do
  @moduledoc """
  Tests for bot token resolution logic in config/runtime.exs.
  """
  use ExUnit.Case, async: false

  setup do
    bot_token = System.get_env("LOLEK_BOT_TOKEN")
    bot_token_file = System.get_env("LOLEK_BOT_TOKEN_FILE")

    on_exit(fn ->
      restore_env("LOLEK_BOT_TOKEN", bot_token)
      restore_env("LOLEK_BOT_TOKEN_FILE", bot_token_file)
    end)
  end

  test "reads bot token from token file when LOLEK_BOT_TOKEN_FILE is set" do
    path = tmp_file("telegram-token\n")

    System.delete_env("LOLEK_BOT_TOKEN")
    System.put_env("LOLEK_BOT_TOKEN_FILE", path)

    assert resolve_bot_token() == "telegram-token"
  end

  test "reads bot token from LOLEK_BOT_TOKEN when no file is configured" do
    System.put_env("LOLEK_BOT_TOKEN", "env-token")
    System.delete_env("LOLEK_BOT_TOKEN_FILE")

    assert resolve_bot_token() == "env-token"
  end

  describe "LOLEK_SOURCE_MESSAGE_MODE" do
    setup do
      mode = System.get_env("LOLEK_SOURCE_MESSAGE_MODE")
      on_exit(fn -> restore_env("LOLEK_SOURCE_MESSAGE_MODE", mode) end)
    end

    test "defaults to raw" do
      System.delete_env("LOLEK_SOURCE_MESSAGE_MODE")

      assert runtime_config(:source_message_mode) == :raw
    end

    test "parses reply and delete" do
      System.put_env("LOLEK_SOURCE_MESSAGE_MODE", "reply")
      assert runtime_config(:source_message_mode) == :reply

      System.put_env("LOLEK_SOURCE_MESSAGE_MODE", "delete")
      assert runtime_config(:source_message_mode) == :delete
    end

    test "rejects unknown modes" do
      System.put_env("LOLEK_SOURCE_MESSAGE_MODE", "forward")

      assert_raise RuntimeError, ~r/LOLEK_SOURCE_MESSAGE_MODE must be one of/, fn ->
        runtime_config(:source_message_mode)
      end
    end
  end

  defp runtime_config(key) do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :test)
    |> Keyword.fetch!(:lolek)
    |> Keyword.fetch!(key)
  end

  defp resolve_bot_token do
    case System.get_env("LOLEK_BOT_TOKEN_FILE") do
      path when path in [nil, ""] -> System.fetch_env!("LOLEK_BOT_TOKEN")
      path -> path |> File.read!() |> String.trim()
    end
  end

  defp tmp_file(contents) do
    path = Path.join(System.tmp_dir!(), "lolek-config-test-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
