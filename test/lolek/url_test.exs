defmodule Lolek.UrlTest do
  use ExUnit.Case, async: true

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
