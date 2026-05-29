defmodule Lolek.FileTest do
  use ExUnit.Case

  @tag :tmp_dir
  test "moves first uploaded file into ready to telegram cache", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "compressed.mp4")
    ready_path = Path.join([tmp_dir, "ready_to_telegram", "telegram-file-id.mp4"])

    File.write!(file_path, "video")

    assert :ok =
             Lolek.File.move_to_ready_to_telegram(
               {:sent_to_telegram_at_first, file_path, "telegram-file-id"}
             )

    assert File.read!(ready_path) == "video"
    refute File.exists?(file_path)
  end

  @tag :tmp_dir
  test "returns an error when uploaded file is missing", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "compressed.mp4")

    assert {:error, :enoent} =
             Lolek.File.move_to_ready_to_telegram(
               {:sent_to_telegram_at_first, file_path, "telegram-file-id"}
             )
  end

  test "ignores file states that do not need caching" do
    assert :ok = Lolek.File.move_to_ready_to_telegram({:ready_to_telegram, "/tmp/file.mp4"})
  end
end
