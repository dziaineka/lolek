defmodule Lolek.Requester do
  @moduledoc """
  Formats Telegram sender information for user-visible bot captions.
  """

  @unknown_requester "Someone"

  @spec display_name(term()) :: String.t()
  def display_name(%ExGram.Model.User{username: username})
      when is_binary(username) and username != "" do
    sanitize_display_name(username)
  end

  def display_name(%ExGram.Model.User{first_name: first_name, last_name: last_name}) do
    [first_name, last_name]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" ")
    |> sanitize_display_name()
  end

  def display_name(_user), do: @unknown_requester

  @spec sanitize_display_name(String.t()) :: String.t()
  defp sanitize_display_name(name) do
    name
    |> String.replace(~r{https?://\S+}iu, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> @unknown_requester
      sanitized -> sanitized
    end
  end
end
