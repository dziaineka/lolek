defmodule Lolek.Url do
  @moduledoc """
  This module is responsible for operations with URLs.
  """
  @url_regex ~r/(:?https|http):\/\/\S+/
  @allowed_urls ["tiktok.com", "twitter.com", "instagram.com", "coub.com", "x.com"]

  @spec extract_url(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_url(text) do
    case Regex.scan(@url_regex, text) do
      [] ->
        {:error, :no_url}

      urls ->
        url = urls |> List.first() |> List.first()

        if Enum.any?(@allowed_urls, &String.contains?(url, &1)) do
          {:ok, url}
        else
          {:error, :no_url}
        end
    end
  end

  @spec to_folder_name(String.t()) :: String.t()
  def to_folder_name(url) do
    url |> String.downcase() |> Base.encode64(padding: false)
  end
end
