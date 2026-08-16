defmodule Lolek.YoutubePostDownloaderTest do
  use ExUnit.Case

  setup do
    allowed_urls_regex = Application.get_env(:lolek, :allowed_urls_regex)
    Application.put_env(:lolek, :allowed_urls_regex, "youtube\\.com\\/(?:shorts|post)")

    on_exit(fn ->
      restore_app_env(:allowed_urls_regex, allowed_urls_regex)
    end)

    :ok
  end

  describe "extract_post/1" do
    test "extracts the post from the page embedded JSON" do
      post = multi_image_post()
      assert {:ok, ^post} = Lolek.YoutubePostDownloader.extract_post(post_page_html(post))
    end

    test "fails when the page has no post data" do
      assert {:error, "YouTube post data was not found"} =
               Lolek.YoutubePostDownloader.extract_post("<html><body>nothing</body></html>")
    end
  end

  describe "extract_caption/1" do
    test "returns the post text from contentText runs" do
      html = post_page_html(multi_image_post())

      assert {:ok, "Folklore, Werewolves & Norwegian Myths"} =
               Lolek.YoutubePostDownloader.extract_caption(html)
    end

    test "returns nil for a post without text" do
      post = %{"postId" => "Ugkx1", "backstageAttachment" => single_image_attachment()}
      assert {:ok, nil} = Lolek.YoutubePostDownloader.extract_caption(post_page_html(post))
    end
  end

  describe "extract_media_items/1" do
    test "collects the largest thumbnail of every image in a multi-image post" do
      html = post_page_html(multi_image_post())

      assert {:ok,
              [
                %{type: :image, url: "https://yt3.ggpht.com/a=s1024"},
                %{type: :image, url: "https://yt3.ggpht.com/b=s1170"}
              ]} = Lolek.YoutubePostDownloader.extract_media_items(html)
    end

    test "collects a single-image attachment" do
      post = %{
        "postId" => "Ugkx1",
        "contentText" => %{"runs" => [%{"text" => "hello"}]},
        "backstageAttachment" => single_image_attachment()
      }

      assert {:ok, [%{type: :image, url: "https://yt3.ggpht.com/c=s1024"}]} =
               Lolek.YoutubePostDownloader.extract_media_items(post_page_html(post))
    end

    test "collects the video attachment as a watch URL" do
      post = %{
        "postId" => "Ugkx1",
        "backstageAttachment" => %{
          "backstageVideoRenderer" => %{
            "videoId" => "dQw4w9WgXcQ",
            "title" => %{"runs" => [%{"text" => "Video title"}]}
          }
        }
      }

      assert {:ok, [%{type: :video, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}]} =
               Lolek.YoutubePostDownloader.extract_media_items(post_page_html(post))
    end

    test "fails for a text-only post" do
      post = %{"postId" => "Ugkx1", "contentText" => %{"runs" => [%{"text" => "hello"}]}}

      assert {:error, "YouTube post media was not found"} =
               Lolek.YoutubePostDownloader.extract_media_items(post_page_html(post))
    end
  end

  describe "normalize_url/1" do
    test "normalizes hosts, schemes, queries, and trailing slashes" do
      assert {:ok, "https://www.youtube.com/post/Ugkx8z60bnLKowJrkktYgJ4uML8rbvnbomWf"} =
               Lolek.YoutubePostDownloader.normalize_url(
                 "http://youtube.com/post/Ugkx8z60bnLKowJrkktYgJ4uML8rbvnbomWf?surface=shorts&si=HW05Owf3Mu5kBbLi"
               )

      assert {:ok, "https://www.youtube.com/post/Ugkx8z60bnLKowJrkktYgJ4uML8rbvnbomWf"} =
               Lolek.YoutubePostDownloader.normalize_url(
                 "https://m.youtube.com/post/Ugkx8z60bnLKowJrkktYgJ4uML8rbvnbomWf/"
               )
    end

    test "rejects non-post YouTube URLs" do
      assert {:error, "Unsupported YouTube post URL"} =
               Lolek.YoutubePostDownloader.normalize_url("https://www.youtube.com/watch?v=abc")

      assert {:error, "Unsupported YouTube post URL"} =
               Lolek.YoutubePostDownloader.normalize_url("https://example.com/post/abc")
    end
  end

  describe "downloader routing" do
    test "routes YouTube post URLs to Lolek.YoutubePostDownloader" do
      assert Lolek.YoutubePostDownloader ==
               Lolek.Downloader.downloader_module(
                 "http://youtube.com/post/Ugkx8z60bnLKowJrkktYgJ4uML8rbvnbomWf?si=abc"
               )

      assert Lolek.YoutubePostDownloader ==
               Lolek.Downloader.downloader_module("https://www.youtube.com/post/Ugkx1/")

      assert Lolek.YoutubePostDownloader ==
               Lolek.Downloader.downloader_module("https://m.youtube.com/post/Ugkx1")
    end

    test "keeps other YouTube URLs on yt-dlp" do
      assert :yt_dlp ==
               Lolek.Downloader.downloader_module("https://www.youtube.com/shorts/abc")

      assert :yt_dlp ==
               Lolek.Downloader.downloader_module("https://www.youtube.com/watch?v=abc")

      assert :yt_dlp ==
               Lolek.Downloader.downloader_module("https://www.youtube.com/feed/subscriptions")
    end
  end

  describe "Lolek.Url" do
    test "accepts YouTube post URLs in the allowlist" do
      url = "http://youtube.com/post/Ugkx8z60bnLKowJrkktYgJ4uML8rbvnbomWf?surface=shorts&si=x"
      assert {:ok, ^url} = Lolek.Url.extract_url("check this out #{url}")
    end

    test "rejects non-post YouTube URLs when only posts are allowed" do
      assert {:error, :no_url} =
               Lolek.Url.extract_url("https://www.youtube.com/feed/subscriptions")
    end

    test "normalizes post URLs to a stable cache folder name" do
      with_query =
        "http://youtube.com/post/Ugkx8z60bnLKowJrkktYgJ4uML8rbvnbomWf?surface=shorts&si=HW05Owf3Mu5kBbLi"

      canonical = "https://www.youtube.com/post/Ugkx8z60bnLKowJrkktYgJ4uML8rbvnbomWf"

      assert Lolek.Url.to_folder_name(with_query) == Lolek.Url.to_folder_name(canonical)
    end
  end

  describe "Lolek.File" do
    test "detects multiple downloaded media files in a cache folder" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "lolek_youtube_post_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "downloaded_001.webp"), "a")
      File.write!(Path.join(tmp, "downloaded_002.webp"), "b")

      on_exit(fn -> File.rm_rf(tmp) end)

      assert {:ok, {:downloaded_media, ^tmp, files}} = Lolek.File.get_file_state(tmp)

      assert files == [
               Path.join(tmp, "downloaded_001.webp"),
               Path.join(tmp, "downloaded_002.webp")
             ]
    end
  end

  defp post_page_html(post_renderer) do
    data = %{
      "responseContext" => %{
        "serviceTrackingParams" => [
          %{
            "service" => "GFEEDBACK",
            "params" => [
              %{"key" => "browse_id", "value" => "FEpost_detail"}
            ]
          }
        ]
      },
      "contents" => %{
        "twoColumnBrowseResultsRenderer" => %{
          "tabs" => [
            %{
              "tabRenderer" => %{
                "content" => %{
                  "sectionListRenderer" => %{
                    "contents" => [
                      %{
                        "itemSectionRenderer" => %{
                          "contents" => [
                            %{
                              "backstagePostThreadRenderer" => %{
                                "post" => %{"backstagePostRenderer" => post_renderer}
                              }
                            }
                          ]
                        }
                      }
                    ]
                  }
                }
              }
            }
          ]
        }
      }
    }

    "<!DOCTYPE html><html><head><script nonce=\"abc\">var ytInitialData = " <>
      Jason.encode!(data) <> ";</script></head><body></body></html>"
  end

  defp multi_image_post do
    %{
      "postId" => "Ugkx8z60bnLKowJrkktYgJ4uML8rbvnbomWf",
      "contentText" => %{
        "runs" => [
          %{"text" => "Folklore, Werewolves "},
          %{"text" => "& Norwegian Myths"}
        ]
      },
      "backstageAttachment" => %{
        "postMultiImageRenderer" => %{
          "images" => [
            %{
              "backstageImageRenderer" => %{
                "image" => %{
                  "thumbnails" => [
                    %{"url" => "https://yt3.ggpht.com/a=s288", "width" => 288, "height" => 288},
                    %{"url" => "https://yt3.ggpht.com/a=s1024", "width" => 1024, "height" => 1024}
                  ]
                }
              }
            },
            %{
              "backstageImageRenderer" => %{
                "image" => %{
                  "thumbnails" => [
                    %{"url" => "https://yt3.ggpht.com/b=s512", "width" => 512, "height" => 512},
                    %{"url" => "https://yt3.ggpht.com/b=s1170", "width" => 1170, "height" => 1170}
                  ]
                }
              }
            }
          ]
        }
      }
    }
  end

  defp single_image_attachment do
    %{
      "backstageImageRenderer" => %{
        "image" => %{
          "thumbnails" => [
            %{"url" => "https://yt3.ggpht.com/c=s288", "width" => 288, "height" => 288},
            %{"url" => "https://yt3.ggpht.com/c=s1024", "width" => 1024, "height" => 1024}
          ]
        }
      }
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:lolek, key)
  defp restore_app_env(key, value), do: Application.put_env(:lolek, key, value)
end
