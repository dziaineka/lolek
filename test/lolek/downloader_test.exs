defmodule Lolek.DownloaderTest do
  use ExUnit.Case, async: true

  test "uses dedicated threads downloader for threads urls" do
    assert Lolek.ThreadsDownloader =
             Lolek.Downloader.downloader_module(
               "https://www.threads.com/@helga_bri/post/DXum65XjCcD"
             )
  end

  test "uses yt-dlp for other urls" do
    assert :yt_dlp = Lolek.Downloader.downloader_module("https://x.com/example/status/1")
  end
end
