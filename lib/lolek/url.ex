defmodule Lolek.Url do
  @moduledoc """
  This module is responsible for operations with URLs.
  """
  @url_regex ~r/(:?https|http):\/\/\S+/

  @spec extract_url(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_url(text) do
    case Regex.scan(@url_regex, text) do
      [] ->
        {:error, :no_url}

      urls ->
        url = urls |> List.first() |> List.first()

        allowed_urls_regex = Application.fetch_env!(:lolek, :allowed_urls_regex)

        if Regex.match?(~r/#{allowed_urls_regex}/, url) do
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
