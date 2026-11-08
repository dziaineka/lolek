defmodule Lolek.Post.Text do
  @moduledoc """
  Cleans post text from source metadata and keeps links, mentions, and hashtags.
  """

  @doc """
  Cleans post text: decodes HTML entities, normalizes line breaks and spaces, and
  removes platform noise (the leading reply mentions and the trailing media link on X).
  """
  @spec clean(term(), Lolek.Post.platform(), keyword()) :: String.t() | nil
  def clean(text, platform, opts \\ [])

  def clean(text, platform, opts) when is_binary(text) do
    text
    |> HtmlEntities.decode()
    # Some sites put this object replacement character where they show media.
    |> String.replace("\u{FFFC}", "")
    |> String.replace(["\r\n", "\r"], "\n")
    |> remove_platform_noise(platform, opts)
    |> String.split("\n")
    |> Enum.map_join("\n", &clean_line/1)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> Lolek.Post.blank_to_nil()
  end

  def clean(_text, _platform, _opts), do: nil

  @spec clean_line(String.t()) :: String.t()
  defp clean_line(line) do
    line
    |> String.replace(~r/[ \t\x{00A0}]+/u, " ")
    |> String.trim()
  end

  @spec remove_platform_noise(String.t(), Lolek.Post.platform(), keyword()) :: String.t()
  defp remove_platform_noise(text, :twitter, opts) do
    text
    # X adds a t.co link to the attached media at the end of the text.
    |> String.replace(~r{\s*https://t\.co/\w+\s*\z}u, "")
    |> then(fn text ->
      if Keyword.get(opts, :reply?, false),
        do: String.replace(text, ~r/\A(?:@\w+\s+)+/u, ""),
        else: text
    end)
  end

  defp remove_platform_noise(text, _platform, _opts), do: text
end
