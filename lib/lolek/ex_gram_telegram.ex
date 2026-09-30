defmodule Lolek.ExGramTelegram do
  @moduledoc """
  Sends Telegram API requests through ExGram.
  """

  @behaviour Lolek.Telegram

  @impl true
  def send_video(chat_id, video, options) do
    ExGram.send_video(chat_id, video, options)
  end

  @impl true
  def send_document(chat_id, document, options) do
    ExGram.send_document(chat_id, document, options)
  end

  @impl true
  def send_photo(chat_id, photo, options) do
    ExGram.send_photo(chat_id, photo, options)
  end

  @impl true
  def send_animation(chat_id, animation, options) do
    ExGram.send_animation(chat_id, animation, options)
  end

  @impl true
  def send_media_group(chat_id, media, options) do
    ExGram.send_media_group(chat_id, media, options)
  end

  @impl true
  def set_message_reaction(chat_id, message_id, options) do
    ExGram.set_message_reaction(chat_id, message_id, options)
  end

  @impl true
  def send_rich_message(chat_id, rich_message, options) do
    case rich_message_multipart(chat_id, rich_message, options) do
      :no_files -> ExGram.send_rich_message(chat_id, rich_message, options)
      {:multipart, _parts} = body -> post_multipart("sendRichMessage", body)
    end
  end

  @impl true
  def delete_message(chat_id, message_id) do
    ExGram.delete_message(chat_id, message_id)
  end

  # ExGram 0.70.1 uploads files only from top-level InputMedia parameters: a file
  # inside rich_message would be JSON-encoded as a tuple and the request would fail.
  # Once an ExGram release uploads files nested in InputRichMessage, drop this and
  # call ExGram.send_rich_message for every rich message.
  @doc false
  @spec rich_message_multipart(integer(), ExGram.Model.InputRichMessage.t(), keyword()) ::
          {:multipart, [tuple()]} | :no_files
  def rich_message_multipart(chat_id, rich_message, options) do
    case attach_files(rich_message, []) do
      {_rich_message, []} ->
        :no_files

      {rich_message, files} ->
        fields =
          Enum.map([chat_id: chat_id, rich_message: rich_message] ++ options, fn {name, value} ->
            {Atom.to_string(name), field_value(value)}
          end)

        {:multipart, Enum.reverse(files) ++ fields}
    end
  end

  @spec attach_files(term(), [tuple()]) :: {term(), [tuple()]}
  defp attach_files({:file_content, _content, _file_name} = file, files), do: attach(file, files)
  defp attach_files({:file, _path} = file, files), do: attach(file, files)

  defp attach_files(list, files) when is_list(list),
    do: Enum.map_reduce(list, files, &attach_files/2)

  defp attach_files(map, files) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.reduce({map, files}, fn {key, value}, {map, files} ->
      {value, files} = attach_files(value, files)
      {Map.put(map, key, value), files}
    end)
  end

  defp attach_files(value, files), do: {value, files}

  @spec attach(tuple(), [tuple()]) :: {String.t(), [tuple()]}
  defp attach(file, files) do
    name = "file#{length(files)}"
    {"attach://#{name}", [file_part(name, file) | files]}
  end

  @spec file_part(String.t(), tuple()) :: tuple()
  defp file_part(name, {:file_content, content, file_name}),
    do: {:file_content, name, content, file_name}

  defp file_part(name, {:file, path}), do: {:file, name, path}

  @spec field_value(term()) :: String.t()
  defp field_value(value) when is_binary(value), do: value
  defp field_value(value) when is_map(value) or is_list(value), do: ExGram.Adapter.encode(value)
  defp field_value(value), do: to_string(value)

  @spec post_multipart(String.t(), {:multipart, [tuple()]}) :: {:ok, term()} | {:error, term()}
  defp post_multipart(method, body) do
    adapter = ExGram.Config.get(:ex_gram, :adapter, ExGram.Adapter.Tesla)
    token_part = "/bot#{ExGram.Token.fetch([])}"

    path =
      if ExGram.test_environment?(),
        do: "#{token_part}/test/#{method}",
        else: "#{token_part}/#{method}"

    with {:ok, result} <- adapter.request(:post, path, body, []) do
      ExGram.Cast.cast(result, ExGram.Model.Message)
    end
  end
end
