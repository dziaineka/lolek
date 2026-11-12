{
  pkgs,
  module,
  package,
  telegym,
  telegymModule,
}:

let
  media = pkgs.runCommand "lolek-video-budget-fixtures" { nativeBuildInputs = [ pkgs.ffmpeg ]; } ''
    mkdir -p "$out"
    ffmpeg -v error -f lavfi -i color=c=blue:s=320x240:r=30 -t 4 \
      -c:v libx264 -pix_fmt yuv420p "$out/passthrough.mp4"
    ffmpeg -v error -f lavfi -i testsrc2=size=320x240:rate=30 -t 4 \
      -c:v libx264 -preset fast -crf 23 "$out/compress.mp4"
    ffmpeg -v error -f lavfi -i testsrc2=size=320x240:rate=30 -t 4 \
      -c:v libx265 -preset fast -crf 44 -x265-params pools=1:log-level=error \
      -tag:v hvc1 "$out/convert.mp4"
  '';
in
pkgs.testers.nixosTest {
  name = "lolek-video-budget";

  containers.machine = {
    imports = [
      module
      telegymModule
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
      pkgs.ffmpeg
    ];
    services.telegym-mock = {
      enable = true;
      package = telegym;
      port = 5678;
    };
    services.lolek = {
      enable = true;
      inherit package;
      botTokenFile = pkgs.writeText "bot-token" "dummy-token";
      allowedUrlPatterns = [ "127.0.0.1" ];
      galleryDownloadEnabled = false;
      maxDownloadTries = 1;
      # Scale the budgets down so real encodes exercise overshoot in a small fixture.
      maxVideoSizeToSendToTelegram = 40000;
      maxAudioSizeToSendToTelegram = 1000;
      maxFileSizeToSendToTelegram = 200000;
      maxFileSizeToCompress = 1000000;
      environment.LOLEK_TELEGRAM_BASE_URL = "http://127.0.0.1:5678";
    };
    systemd.services.media-origin = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8081 --bind 127.0.0.1 --directory ${media}";
    };
  };

  testScript = builtins.readFile ./video-budget.py + ''
    machine.wait_for_unit("media-origin.service")
    machine.wait_for_unit("lolek.service")
    test_video_budget(machine, subtest, "${media}")
  '';
}
