defmodule Lolek.ConfigTest do
  use ExUnit.Case, async: false

  setup do
    bot_token = System.get_env("LOLEK_BOT_TOKEN")
    bot_token_file = System.get_env("LOLEK_BOT_TOKEN_FILE")

    on_exit(fn ->
      restore_env("LOLEK_BOT_TOKEN", bot_token)
      restore_env("LOLEK_BOT_TOKEN_FILE", bot_token_file)
    end)
  end

  test "reads bot token from token file when configured" do
    path = tmp_file("telegram-token\n")

    System.delete_env("LOLEK_BOT_TOKEN")
    System.put_env("LOLEK_BOT_TOKEN_FILE", path)

    assert Lolek.Config.get_bot_token([]) == "telegram-token"
  end

  test "reads bot token from direct environment" do
    System.put_env("LOLEK_BOT_TOKEN", "env-token")
    System.delete_env("LOLEK_BOT_TOKEN_FILE")

    assert Lolek.Config.get_bot_token([]) == "env-token"
  end

  test "reads bot token from dotenv files" do
    default_path = tmp_file("LOLEK_BOT_TOKEN=default-token\n")
    override_path = tmp_file("LOLEK_BOT_TOKEN=override-token\n")

    System.delete_env("LOLEK_BOT_TOKEN")
    System.delete_env("LOLEK_BOT_TOKEN_FILE")

    assert Lolek.Config.get_bot_token([default_path, override_path]) == "override-token"
  end

  defp tmp_file(contents) do
    path = Path.join(System.tmp_dir!(), "lolek-config-test-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
