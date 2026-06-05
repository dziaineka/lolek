defmodule Lolek.ThreadsDownloaderTest do
  use ExUnit.Case, async: true

  test "normalizes threads.net url to threads.com without query" do
    assert {:ok, "https://www.threads.com/@helga_bri/post/DXum65XjCcD"} =
             Lolek.ThreadsDownloader.normalize_url(
               "https://threads.net/@helga_bri/post/DXum65XjCcD?xmt=123"
             )
  end

  test "extracts shortcode from threads post url" do
    assert {:ok, "DXum65XjCcD"} =
             Lolek.ThreadsDownloader.extract_shortcode(
               "https://www.threads.com/@helga_bri/post/DXum65XjCcD"
             )
  end

  test "decodes shortcode into numeric post id" do
    assert {:ok, "3886214701562734339"} = Lolek.ThreadsDownloader.decode_shortcode("DXum65XjCcD")
  end

  test "extracts tokens from threads html" do
    html =
      ~s(<script type="application/json">{"require":[["LSD",[],{"token":"lsd-token"}],["InstagramSecurityConfig",[],{"csrf_token":"csrf-token"}],["WebBloksVersioningID",[],{"versioningID":"version-id"}],["HasteSupportData","handle",null,[{"gkxData":{"4511":{"result":true,"hash":null},"6542":{"result":true,"hash":null},"8583":{"result":true,"hash":null},"21940":{"result":true,"hash":null}},"metaconfigData":{"92":{"value":false}},"qexData":{"1013":{"r":null},"552":{"r":null}}}]]}</script>)

    response = %{
      body: html,
      headers: [{"set-cookie", "csrftoken=cookie-csrf; Path=/; Secure"}],
      status: 200
    }

    assert {:ok,
            %{
              lsd: "lsd-token",
              csrf_token: "csrf-token",
              cookie_csrf_token: "cookie-csrf",
              x_bloks_version_id: "version-id",
              provider_variables: provider_variables
            }} = Lolek.ThreadsDownloader.extract_tokens(response)

    assert provider_variables["__relay_internal__pv__BarcelonaHasCommunitiesrelayprovider"] ==
             true

    assert provider_variables[
             "__relay_internal__pv__BarcelonaHasDearAlgoConsumptionrelayprovider"
           ] == true

    assert provider_variables[
             "__relay_internal__pv__BarcelonaHasPublicViewCountCardrelayprovider"
           ] == true

    assert provider_variables[
             "__relay_internal__pv__BarcelonaOptionalCookiesEnabledrelayprovider"
           ] == true

    assert provider_variables[
             "__relay_internal__pv__BarcelonaHasInlineReplyComposerrelayprovider"
           ] == false
  end

  test "extracts media url from graphql response" do
    body =
      ~s({"data":{"video_versions":[{"url":"https:\/\/cdn.example.com\/video.mp4?foo=bar"}]}})

    assert {:ok, "https://cdn.example.com/video.mp4?foo=bar"} =
             Lolek.ThreadsDownloader.extract_media_url(body)
  end

  test "extracts caption text from graphql response" do
    body = ~s({"data":{"post":{"caption":{"text":"Threads post text"}}}})

    assert {:ok, "Threads post text"} = Lolek.ThreadsDownloader.extract_caption(body)
  end

  test "extracts caption text from text fragments" do
    body =
      ~s({"data":{"post":{"text_post_app_info":{"text_fragments":{"fragments":[{"plaintext":"Hello "},{"plaintext":"Threads"}]}}}}})

    assert {:ok, "Hello Threads"} = Lolek.ThreadsDownloader.extract_caption(body)
  end

  test "builds permalink graphql request with provider variables first" do
    requests =
      Lolek.ThreadsDownloader.graphql_requests(
        "https://www.threads.com/@helga_bri/post/DXum65XjCcD",
        "3886214701562734339",
        %{
          lsd: "lsd-token",
          csrf_token: "csrf-token",
          cookie_csrf_token: "cookie-csrf",
          x_bloks_version_id: "version-id",
          provider_variables: %{
            "__relay_internal__pv__BarcelonaHasCommunitiesrelayprovider" => true,
            "__relay_internal__pv__BarcelonaHasDearAlgoConsumptionrelayprovider" => true
          }
        }
      )

    assert [
             %{
               doc_id: "26667056749611275",
               variables: %{
                 "postID" => "3886214701562734339",
                 "__relay_internal__pv__BarcelonaHasCommunitiesrelayprovider" => true,
                 "__relay_internal__pv__BarcelonaHasDearAlgoConsumptionrelayprovider" => true
               }
             }
             | _
           ] =
             requests
  end

  test "normalizes media route back to canonical post url" do
    assert {:ok, "https://www.threads.com/@helga_bri/post/DXum65XjCcD"} =
             Lolek.ThreadsDownloader.normalize_url(
               "https://www.threads.com/@helga_bri/post/DXum65XjCcD/media?xmt=123"
             )
  end
end
