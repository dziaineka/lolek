defmodule Lolek.Url do
  @url_regex ~r/(:?https|http):\/\/\S+/

  @spec extract_url(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_url(text) do
    case Regex.scan(@url_regex, text) do
      [] ->
        {:error, :no_url}

      urls ->
        {:ok, urls |> List.first() |> List.first()}
    end
  end

  @spec to_folder_name(String.t()) :: String.t()
  def to_folder_name(url) do
    url |> String.downcase() |> Base.encode64(padding: false)
  end
end
