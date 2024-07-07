defmodule Lolek.Url do
  @url_regex ~r/(:?https|http):\/\/\S+/

  @spec extract_url(String.t()) :: String.t() | nil
  def extract_url(text) do
    case Regex.scan(@url_regex, text) do
      [] ->
        nil

      urls ->
        urls |> List.first() |> List.first()
    end
  end
end
