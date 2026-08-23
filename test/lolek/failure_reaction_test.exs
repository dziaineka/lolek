defmodule Lolek.FailureReactionTest do
  use ExUnit.Case

  defmodule TelegramClient do
    @moduledoc false

    @spec set_message_reaction(integer(), integer(), keyword()) :: {:ok, true} | {:error, term()}
    def set_message_reaction(chat_id, message_id, options) do
      send(Application.fetch_env!(:lolek, :failure_reaction_test_parent), {
        :set_message_reaction,
        chat_id,
        message_id,
        options
      })

      case Application.fetch_env!(:lolek, :failure_reaction_test_result) do
        :raise -> raise "reaction failed"
        result -> result
      end
    end
  end

  setup do
    original_env =
      Map.new(
        [
          :failure_reactions_enabled,
          :failure_reaction_test_parent,
          :failure_reaction_test_result,
          :telegram_client
        ],
        &{&1, Application.fetch_env(:lolek, &1)}
      )

    Application.put_env(:lolek, :failure_reactions_enabled, true)
    Application.put_env(:lolek, :failure_reaction_test_parent, self())
    Application.put_env(:lolek, :failure_reaction_test_result, {:ok, true})
    Application.put_env(:lolek, :telegram_client, TelegramClient)

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, {:ok, value}} -> Application.put_env(:lolek, key, value)
        {key, :error} -> Application.delete_env(:lolek, key)
      end)
    end)
  end

  test "maps supported failure reasons to reactions" do
    expected_reactions = [
      too_big_media: "🐳",
      chat_rate_limited: "🥱",
      processing_deadline_exceeded: "😴",
      unexpected_error: "😢"
    ]

    Enum.each(expected_reactions, fn {reason, emoji} ->
      assert :ok = Lolek.FailureReaction.react(123, 456, reason)

      assert_receive {:set_message_reaction, 123, 456,
                      [
                        reaction: [%ExGram.Model.ReactionTypeEmoji{type: "emoji", emoji: ^emoji}],
                        is_big: true
                      ]}
    end)
  end

  test "does not call Telegram when failure reactions are disabled" do
    Application.put_env(:lolek, :failure_reactions_enabled, false)

    assert :ok = Lolek.FailureReaction.react(123, 456, :too_big_media)
    refute_receive {:set_message_reaction, _, _, _}
  end

  test "ignores Telegram reaction errors" do
    Application.put_env(:lolek, :failure_reaction_test_result, {:error, :denied})

    assert :ok = Lolek.FailureReaction.react(123, 456, :unexpected)
  end

  test "ignores exceptions while reacting" do
    Application.put_env(:lolek, :failure_reaction_test_result, :raise)

    assert :ok = Lolek.FailureReaction.react(123, 456, :unexpected)
  end
end
