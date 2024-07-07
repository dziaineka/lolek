defmodule LolekTest do
  use ExUnit.Case
  doctest Lolek

  test "greets the world" do
    assert Lolek.hello() == :world
  end
end
