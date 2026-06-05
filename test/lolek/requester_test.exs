defmodule Lolek.RequesterTest do
  use ExUnit.Case

  test "uses public usernames as display names" do
    user = %ExGram.Model.User{id: 1, is_bot: false, first_name: "Alice", username: "alice"}

    assert Lolek.Requester.display_name(user) == "alice"
  end

  test "falls back to visible first and last names" do
    user = %ExGram.Model.User{id: 1, is_bot: false, first_name: "Alice", last_name: "Smith"}

    assert Lolek.Requester.display_name(user) == "Alice Smith"
  end

  test "removes urls from visible names" do
    user = %ExGram.Model.User{
      id: 1,
      is_bot: false,
      first_name: "Alice https://threads.com/@example/post/1",
      last_name: "Smith"
    }

    assert Lolek.Requester.display_name(user) == "Alice Smith"
  end

  test "falls back when visible name is only urls" do
    user = %ExGram.Model.User{
      id: 1,
      is_bot: false,
      first_name: "https://threads.com/@example/post/1",
      last_name: "http://youtube.com/watch?v=example"
    }

    assert Lolek.Requester.display_name(user) == "Someone"
  end

  test "does not expose user ids as fallback names" do
    assert Lolek.Requester.display_name(nil) == "Someone"
  end
end
