defmodule Lolek.Requester do
  @moduledoc """
  Formats Telegram sender information for user-visible bot captions.
  """

  @unknown_requester "Someone"

  @spec display_name(term()) :: String.t()
  def display_name(%ExGram.Model.User{username: username})
      when is_binary(username) and username != "" do
    username
  end

  def display_name(%ExGram.Model.User{first_name: first_name, last_name: last_name}) do
    [first_name, last_name]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" ")
    |> case do
      "" -> @unknown_requester
      name -> name
    end
  end

  def display_name(_user), do: @unknown_requester
end
