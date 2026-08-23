defmodule Lolek.TelegramTest do
  use ExUnit.Case

  defmodule TelegramClient do
    @moduledoc false

    @spec set_message_reaction(integer(), integer(), keyword()) :: {:ok, true}
    def set_message_reaction(chat_id, message_id, options) do
      send(Application.fetch_env!(:lolek, :telegram_test_parent), {
        :set_message_reaction,
        chat_id,
        message_id,
        options
      })

      {:ok, true}
    end
  end

  setup do
    telegram_client = Application.get_env(:lolek, :telegram_client)
    telegram_test_parent = Application.get_env(:lolek, :telegram_test_parent)

    Application.put_env(:lolek, :telegram_client, TelegramClient)
    Application.put_env(:lolek, :telegram_test_parent, self())

    on_exit(fn ->
      restore_app_env(:telegram_client, telegram_client)
      restore_app_env(:telegram_test_parent, telegram_test_parent)
    end)
  end

  test "sets a reaction on a Telegram message" do
    reaction = [%ExGram.Model.ReactionTypeEmoji{type: "emoji", emoji: "🐳"}]

    assert {:ok, true} =
             Lolek.Telegram.set_message_reaction(123, 456, reaction: reaction, is_big: true)

    assert_receive {:set_message_reaction, 123, 456, [reaction: ^reaction, is_big: true]}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:lolek, key)
  defp restore_app_env(key, value), do: Application.put_env(:lolek, key, value)
end
