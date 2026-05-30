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

  test "does not expose user ids as fallback names" do
    assert Lolek.Requester.display_name(nil) == "Someone"
  end
end
