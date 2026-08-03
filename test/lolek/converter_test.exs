defmodule Lolek.ConverterTest do
  use ExUnit.Case

  @converter_env_keys [
    :max_file_size_to_send_to_telegram,
    :max_video_size_to_send_to_telegram,
    :max_audio_size_to_send_to_telegram,
    :max_file_size_to_compress,
    :max_duration_to_compress,
    :convert_command_timeout_seconds,
    :probe_command_timeout_seconds,
    :hw_acceleration,
    :hw_device
  ]

  @tag :tmp_dir
  test "returns an error when downloaded mp4 is missing", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "downloaded.mp4")

    assert {:error, :no_usable_media_files} =
             Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})
  end

  @tag :tmp_dir
  test "returns an error when video duration cannot be determined", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")

      File.write!(file_path, "video")
      put_fake_executable(bin_dir, "ffprobe", "exit 1")
      Application.put_env(:lolek, :probe_command_timeout_seconds, 5)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :no_usable_media_files} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})
    end)
  end

  @tag :tmp_dir
  test "returns an error when ffmpeg encode fails", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")
      put_fake_executable(bin_dir, "ffmpeg", "exit 1")
      put_compression_env()

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, _reason} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})
    end)
  end

  @tag :tmp_dir
  test "removes partial compressed output when ffmpeg encode fails", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")
      compressed_path = Path.join(tmp_dir, "compressed.mp4")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do
        output="$arg"
      done
      printf partial > "$output"
      exit 1
      """)

      put_compression_env()

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, _reason} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.exists?(file_path)
      refute File.exists?(compressed_path)
    end)
  end

  @tag :tmp_dir
  test "returns an error when ffmpeg succeeds without output", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")
      put_fake_executable(bin_dir, "ffmpeg", "exit 0")
      put_compression_env()

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :no_usable_media_files} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})
    end)
  end

  @tag :tmp_dir
  test "returns an error when downloaded file is missing", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "downloaded.txt")

    assert {:error, :no_usable_media_files} =
             Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})
  end

  @tag :tmp_dir
  test "keeps a compatible video without invoking ffmpeg", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")
      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")
      put_fake_executable(bin_dir, "ffmpeg", "exit 1")
      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 100)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [^file_path]}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.read!(file_path) == String.duplicate("x", 10)
    end)
  end

  @tag :tmp_dir
  test "converts a non-mp4 video even when its codec is h264", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mkv")
      compressed_path = Path.join(tmp_dir, "compressed.mp4")
      ffmpeg_args_file = Path.join(tmp_dir, "ffmpeg.args")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do
        printf '%s\\n' "$arg" >> "#{ffmpeg_args_file}"
        output="$arg"
      done
      printf ok > "$output"
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 100)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [^compressed_path]}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.read!(compressed_path) == "ok"
      assert File.read!(ffmpeg_args_file) =~ "-c:v\nlibx264\n"
      refute File.exists?(file_path)
    end)
  end

  @tag :tmp_dir
  test "rejects videos above the conversion input limit", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")
      compressed_path = Path.join(tmp_dir, "compressed.mp4")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")
      put_fake_executable(bin_dir, "ffmpeg", "exit 1")
      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_compress, 5)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :no_usable_media_files} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.exists?(file_path)
      refute File.exists?(compressed_path)
    end)
  end

  @tag :tmp_dir
  test "removes encoded output that remains above the upload limit", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")
      compressed_path = Path.join(tmp_dir, "compressed.mp4")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do output="$arg"; done
      printf toolarge > "$output"
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :no_usable_media_files} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.exists?(file_path)
      refute File.exists?(compressed_path)
    end)
  end

  @tag :tmp_dir
  test "prepares gallery videos while preserving media order", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      gallery_dir = Path.join(tmp_dir, "gallery")
      File.mkdir_p!(gallery_dir)

      first_image = Path.join(gallery_dir, "01.jpg")
      oversized_video = Path.join(gallery_dir, "02.mp4")
      second_image = Path.join(gallery_dir, "03.png")
      small_video = Path.join(gallery_dir, "04.mp4")
      prepared_video = oversized_video <> ".telegram.mp4"

      File.write!(first_image, "i")
      File.write!(oversized_video, String.duplicate("v", 10))
      File.write!(second_image, "i")
      File.write!(small_video, "vid")
      put_video_probe(bin_dir, "10.0", "h264")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do output="$arg"; done
      printf ok > "$output"
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      files = [first_image, oversized_video, second_image, small_video]

      assert {:ok, {:prepared_media, ^tmp_dir, prepared_files}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, files})

      assert prepared_files == [first_image, prepared_video, second_image, small_video]
      assert File.read!(prepared_video) == "ok"
      refute File.exists?(oversized_video)
      assert File.exists?(small_video)
    end)
  end

  @tag :tmp_dir
  test "omits gallery media that cannot be prepared", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      gallery_dir = Path.join(tmp_dir, "gallery")
      File.mkdir_p!(gallery_dir)

      image = Path.join(gallery_dir, "01.jpg")
      video = Path.join(gallery_dir, "02.mp4")

      File.write!(image, "image")
      File.write!(video, String.duplicate("v", 10))
      put_video_probe(bin_dir, "1000.0", "h264")
      put_fake_executable(bin_dir, "ffmpeg", "exit 1")
      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [^image]}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [image, video]})

      assert File.exists?(video)
      refute File.exists?(video <> ".telegram.mp4")
    end)
  end

  @tag :tmp_dir
  test "omits oversized gallery images while keeping usable media", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      gallery_dir = Path.join(tmp_dir, "gallery")
      File.mkdir_p!(gallery_dir)

      oversized_image = Path.join(gallery_dir, "01.jpg")
      usable_image = Path.join(gallery_dir, "02.jpg")

      File.write!(oversized_image, String.duplicate("i", 10))
      File.write!(usable_image, "image")
      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)

      assert {:ok, {:prepared_media, ^tmp_dir, [^usable_image]}} =
               Lolek.Converter.adapt_to_telegram(
                 {:downloaded_media, tmp_dir, [oversized_image, usable_image]}
               )
    end)
  end

  @tag :tmp_dir
  test "returns an error when no gallery media can be prepared", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      gallery_dir = Path.join(tmp_dir, "gallery")
      File.mkdir_p!(gallery_dir)
      video = Path.join(gallery_dir, "video.mp4")

      File.write!(video, String.duplicate("v", 10))
      put_video_probe(bin_dir, "1000.0", "h264")
      put_fake_executable(bin_dir, "ffmpeg", "exit 1")
      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :no_usable_media_files} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [video]})
    end)
  end

  @tag :tmp_dir
  test "converts a heic image to jpeg", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join([tmp_dir, "gallery", "001.heic"])
      prepared_path = file_path <> ".telegram.jpg"
      ffmpeg_args_file = Path.join(tmp_dir, "ffmpeg.args")

      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "heic data")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do
        printf '%s\\n' "$arg" >> "#{ffmpeg_args_file}"
        output="$arg"
      done
      printf ok > "$output"
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 100)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [^prepared_path]}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.read!(prepared_path) == "ok"
      refute File.exists?(file_path)

      ffmpeg_args = File.read!(ffmpeg_args_file)
      assert ffmpeg_args =~ "-i\n#{file_path}\n"
      assert ffmpeg_args =~ "-q:v\n2\n"
      assert ffmpeg_args =~ "#{prepared_path}\n"
    end)
  end

  @tag :tmp_dir
  test "converts webp and avif images to jpeg", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      gallery_dir = Path.join(tmp_dir, "gallery")
      File.mkdir_p!(gallery_dir)
      webp_path = Path.join(gallery_dir, "01.webp")
      avif_path = Path.join(gallery_dir, "02.avif")
      prepared_webp = webp_path <> ".telegram.jpg"
      prepared_avif = avif_path <> ".telegram.jpg"

      File.write!(webp_path, "webp data")
      File.write!(avif_path, "avif data")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do output="$arg"; done
      printf ok > "$output"
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 100)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [^prepared_webp, ^prepared_avif]}} =
               Lolek.Converter.adapt_to_telegram(
                 {:downloaded_media, tmp_dir, [webp_path, avif_path]}
               )

      assert File.read!(prepared_webp) == "ok"
      assert File.read!(prepared_avif) == "ok"
      refute File.exists?(webp_path)
      refute File.exists?(avif_path)
    end)
  end

  @tag :tmp_dir
  test "keeps png and jpeg images without invoking ffmpeg", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      png_path = Path.join([tmp_dir, "gallery", "01.png"])
      jpeg_path = Path.join([tmp_dir, "gallery", "02.jpeg"])

      File.mkdir_p!(Path.dirname(png_path))
      File.write!(png_path, "png data")
      File.write!(jpeg_path, "jpeg data")
      put_fake_executable(bin_dir, "ffmpeg", "exit 1")
      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 100)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [^png_path, ^jpeg_path]}} =
               Lolek.Converter.adapt_to_telegram(
                 {:downloaded_media, tmp_dir, [png_path, jpeg_path]}
               )

      assert File.read!(png_path) == "png data"
      assert File.read!(jpeg_path) == "jpeg data"
    end)
  end

  @tag :tmp_dir
  test "keeps gif images without invoking ffmpeg", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join([tmp_dir, "gallery", "01.gif"])

      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "gif data")
      put_fake_executable(bin_dir, "ffmpeg", "exit 1")
      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 100)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [^file_path]}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})
    end)
  end

  @tag :tmp_dir
  test "omits image when ffmpeg conversion fails", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join([tmp_dir, "gallery", "001.heic"])
      prepared_path = file_path <> ".telegram.jpg"

      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "heic data")
      put_fake_executable(bin_dir, "ffmpeg", "exit 1")
      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 100)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :no_usable_media_files} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.exists?(file_path)
      refute File.exists?(prepared_path)
    end)
  end

  @tag :tmp_dir
  test "removes converted image output that remains above the upload limit", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join([tmp_dir, "gallery", "001.heic"])
      prepared_path = file_path <> ".telegram.jpg"

      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "heic data")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do output="$arg"; done
      printf toolarge > "$output"
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:error, :no_usable_media_files} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.exists?(file_path)
      refute File.exists?(prepared_path)
    end)
  end

  @tag :tmp_dir
  test "uses vaapi encoder when configured", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")
      ffmpeg_args_file = Path.join(tmp_dir, "ffmpeg.args")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do
        printf '%s\\n' "$arg" >> "#{ffmpeg_args_file}"
        output="$arg"
      done
      printf ok > "$output"
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)
      Application.put_env(:lolek, :hw_acceleration, "vaapi")
      Application.put_env(:lolek, :hw_device, "/dev/dri/renderD128")

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [compressed_path]}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.read!(compressed_path) == "ok"

      ffmpeg_args = File.read!(ffmpeg_args_file)
      assert ffmpeg_args =~ "-hwaccel\nvaapi\n"
      assert ffmpeg_args =~ "-hwaccel_device\n/dev/dri/renderD128\n"
      assert ffmpeg_args =~ "-hwaccel_output_format\nvaapi\n"
      assert ffmpeg_args =~ "-vaapi_device\n/dev/dri/renderD128\n"
      assert ffmpeg_args =~ "-vf\nformat=nv12,hwupload\n"
      assert ffmpeg_args =~ "-c:v\nh264_vaapi\n"
      assert ffmpeg_args =~ "-profile:v\nconstrained_baseline\n"
      refute ffmpeg_args =~ "libx264"
    end)
  end

  @tag :tmp_dir
  test "falls back to software encoder when vaapi fails", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")
      ffmpeg_args_file = Path.join(tmp_dir, "ffmpeg.args")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do
        printf '%s\\n' "$arg" >> "#{ffmpeg_args_file}"
        output="$arg"
      done
      printf -- '---\\n' >> "#{ffmpeg_args_file}"

      case "$*" in
        *h264_vaapi*)
          printf partial > "$output"
          exit 1
          ;;
        *)
          printf ok > "$output"
          ;;
      esac
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)
      Application.put_env(:lolek, :hw_acceleration, "vaapi")
      Application.put_env(:lolek, :hw_device, "/dev/dri/renderD128")

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [compressed_path]}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.read!(compressed_path) == "ok"

      ffmpeg_args = File.read!(ffmpeg_args_file)
      assert ffmpeg_args =~ "-hwaccel\nvaapi\n"
      assert ffmpeg_args =~ "-hwaccel_device\n/dev/dri/renderD128\n"
      assert ffmpeg_args =~ "-hwaccel_output_format\nvaapi\n"
      assert ffmpeg_args =~ "-c:v\nh264_vaapi\n"
      assert ffmpeg_args =~ "-c:v\nlibx264\n"
    end)
  end

  @tag :tmp_dir
  test "uses qsv encoder when configured", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")
      ffmpeg_args_file = Path.join(tmp_dir, "ffmpeg.args")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do
        printf '%s\\n' \"$arg\" >> \"#{ffmpeg_args_file}\"
        output=\"$arg\"
      done
      printf ok > \"$output\"
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)
      Application.put_env(:lolek, :hw_acceleration, "qsv")
      Application.put_env(:lolek, :hw_device, "/dev/dri/renderD128")

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [compressed_path]}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.read!(compressed_path) == "ok"

      ffmpeg_args = File.read!(ffmpeg_args_file)

      assert ffmpeg_args =~
               "-init_hw_device\nqsv=hw,child_device=/dev/dri/renderD128,child_device_type=vaapi\n"

      assert ffmpeg_args =~ "-filter_hw_device\nhw\n"
      assert ffmpeg_args =~ "-hwaccel\nqsv\n"
      assert ffmpeg_args =~ "-hwaccel_device\nhw\n"
      assert ffmpeg_args =~ "-hwaccel_output_format\nqsv\n"
      assert ffmpeg_args =~ "-c:v\nh264_qsv\n"
      assert ffmpeg_args =~ "-profile:v\nmain\n"
      refute ffmpeg_args =~ "libx264"
    end)
  end

  @tag :tmp_dir
  test "falls back to software encoder when qsv fails", %{tmp_dir: tmp_dir} do
    preserve_converter_env(fn ->
      bin_dir = Path.join(tmp_dir, "bin")
      file_path = Path.join(tmp_dir, "downloaded.mp4")
      ffmpeg_args_file = Path.join(tmp_dir, "ffmpeg.args")

      File.write!(file_path, String.duplicate("x", 10))
      put_video_probe(bin_dir, "10.0", "h264")

      put_fake_executable(bin_dir, "ffmpeg", """
      output=
      for arg do
        printf '%s\\n' \"$arg\" >> \"#{ffmpeg_args_file}\"
        output=\"$arg\"
      done
      printf -- '---\\n' >> \"#{ffmpeg_args_file}\"

      case \"$*\" in
        *h264_qsv*)
          printf partial > \"$output\"
          exit 1
          ;;
        *)
          printf ok > \"$output\"
          ;;
      esac
      """)

      put_compression_env()
      Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 5)
      Application.put_env(:lolek, :hw_acceleration, "qsv")
      Application.put_env(:lolek, :hw_device, "/dev/dri/renderD128")

      System.put_env("PATH", bin_dir <> path_delimiter() <> System.get_env("PATH", ""))
      {:ok, _apps} = Application.ensure_all_started(:erlexec)

      assert {:ok, {:prepared_media, ^tmp_dir, [compressed_path]}} =
               Lolek.Converter.adapt_to_telegram({:downloaded_media, tmp_dir, [file_path]})

      assert File.read!(compressed_path) == "ok"

      ffmpeg_args = File.read!(ffmpeg_args_file)

      assert ffmpeg_args =~
               "-init_hw_device\nqsv=hw,child_device=/dev/dri/renderD128,child_device_type=vaapi\n"

      assert ffmpeg_args =~ "-filter_hw_device\nhw\n"
      assert ffmpeg_args =~ "-hwaccel\nqsv\n"
      assert ffmpeg_args =~ "-hwaccel_device\nhw\n"
      assert ffmpeg_args =~ "-hwaccel_output_format\nqsv\n"
      assert ffmpeg_args =~ "-c:v\nh264_qsv\n"
      assert ffmpeg_args =~ "-c:v\nlibx264\n"
    end)
  end

  defp preserve_converter_env(fun) do
    app_env = Map.new(@converter_env_keys, &{&1, Application.fetch_env(:lolek, &1)})
    path = System.get_env("PATH")

    try do
      fun.()
    after
      Enum.each(app_env, fn
        {key, {:ok, value}} -> Application.put_env(:lolek, key, value)
        {key, :error} -> Application.delete_env(:lolek, key)
      end)

      restore_env("PATH", path)
    end
  end

  defp put_compression_env do
    Application.put_env(:lolek, :max_file_size_to_send_to_telegram, 1)
    Application.put_env(:lolek, :max_video_size_to_send_to_telegram, 800)
    Application.put_env(:lolek, :max_audio_size_to_send_to_telegram, 200)
    Application.put_env(:lolek, :max_file_size_to_compress, 100)
    Application.put_env(:lolek, :max_duration_to_compress, 100)
    Application.put_env(:lolek, :convert_command_timeout_seconds, 5)
    Application.put_env(:lolek, :probe_command_timeout_seconds, 5)
    Application.put_env(:lolek, :hw_acceleration, "none")
    Application.put_env(:lolek, :hw_device, "/dev/dri/renderD128")
  end

  defp put_video_probe(bin_dir, duration, codec) do
    put_fake_executable(bin_dir, "ffprobe", """
    case "$*" in
      *stream=codec_type,duration*)
        printf '{"streams":[{"codec_type":"video","duration":"#{duration}"}],"format":{}}\\n'
        ;;
      *stream=codec_name*)
        printf '#{codec}\\n'
        ;;
      *)
        exit 1
        ;;
    esac
    """)
  end

  defp put_fake_executable(bin_dir, name, body) do
    file_path = Path.join(bin_dir, name)

    File.mkdir_p!(bin_dir)

    File.write!(file_path, """
    #!/bin/sh
    #{body}
    """)

    File.chmod!(file_path, 0o755)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp path_delimiter do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end
end
