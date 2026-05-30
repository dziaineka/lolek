defmodule Lolek.UrlTest do
  use ExUnit.Case, async: false

  setup do
    original_allowed_urls_regex = Application.get_env(:lolek, :allowed_urls_regex)
    Application.put_env(:lolek, :allowed_urls_regex, "threads\\.com")

    on_exit(fn ->
      if is_nil(original_allowed_urls_regex) do
        Application.delete_env(:lolek, :allowed_urls_regex)
      else
        Application.put_env(:lolek, :allowed_urls_regex, original_allowed_urls_regex)
      end
    end)
  end

  test "extracts threads url with query string" do
    assert {:ok,
            "https://www.threads.com/@helga_bri/post/DXum65XjCcD?xmt=AQF01ATXYQOmKTzQNw2Idv0OYXD0th2N-PxIKHR_ljKxaoQKCyAY9GfHmN2KJ5"} =
             Lolek.Url.extract_url(
               "https://www.threads.com/@helga_bri/post/DXum65XjCcD?xmt=AQF01ATXYQOmKTzQNw2Idv0OYXD0th2N-PxIKHR_ljKxaoQKCyAY9GfHmN2KJ5"
             )
  end

  test "rejects urls with allowed domain only in query string" do
    assert {:error, :no_url} =
             Lolek.Url.extract_url(
               "https://example.com/watch?next=https://www.threads.com/@helga/post/1"
             )
  end

  test "rejects urls with allowed domain only in path" do
    assert {:error, :no_url} =
             Lolek.Url.extract_url("https://example.com/https://www.threads.com/@helga/post/1")
  end

  test "rejects hosts that only contain an allowed domain as a substring" do
    assert {:error, :no_url} =
             Lolek.Url.extract_url("https://evilthreads.com/@helga/post/1")

    assert {:error, :no_url} =
             Lolek.Url.extract_url("https://threads.com.example.com/@helga/post/1")
  end

  test "supports path-specific allowlist entries" do
    Application.put_env(:lolek, :allowed_urls_regex, "youtube\\.com/shorts")

    assert {:ok, "https://www.youtube.com/shorts/example"} =
             Lolek.Url.extract_url("https://www.youtube.com/shorts/example")

    assert {:error, :no_url} =
             Lolek.Url.extract_url("https://www.youtube.com/watch?v=example")
  end

  test "does not match path-specific allowlist entries from query strings" do
    Application.put_env(:lolek, :allowed_urls_regex, "youtube\\.com/shorts")

    assert {:error, :no_url} =
             Lolek.Url.extract_url(
               "https://example.com/watch?next=https://www.youtube.com/shorts/example"
             )
  end

  test "threads storage key ignores media path and query string" do
    canonical =
      Lolek.Url.to_folder_name("https://www.threads.com/@slothconservation/post/DXu0QIympQM")

    media_variant =
      Lolek.Url.to_folder_name(
        "https://www.threads.com/@slothconservation/post/DXu0QIympQM/media?xmt=abc123"
      )

    net_variant =
      Lolek.Url.to_folder_name(
        "https://threads.net/@slothconservation/post/DXu0QIympQM?xmt=abc123"
      )

    assert canonical == media_variant
    assert canonical == net_variant
  end
end
