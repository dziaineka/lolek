{
  pkgs,
  module,
  package,
  telegym,
  telegymModule,
}:

let
  media = pkgs.runCommand "private-media-fixtures" { nativeBuildInputs = [ pkgs.ffmpeg ]; } ''
    mkdir -p "$out"
    ffmpeg -f lavfi -i color=c=red:s=160x90:r=10 -t 1 \
      -c:v libx264 -pix_fmt yuv420p "$out/01.mp4"
    ffmpeg -f lavfi -i color=c=blue:s=160x90 -frames:v 1 "$out/02.jpg"
  '';
  gallery = pkgs.linkFarm "private-media-gallery" [
    {
      name = "index.html";
      path = pkgs.writeText "gallery.html" ''
        <!doctype html>
        <html><head><title>Mixed gallery</title></head><body>
          <video src="01.mp4" controls></video>
          <img src="02.jpg" alt="Blue rectangle">
        </body></html>
      '';
    }
    {
      name = "01.mp4";
      path = "${media}/01.mp4";
    }
    {
      name = "02.jpg";
      path = "${media}/02.jpg";
    }
  ];
  galleryConfig = pkgs.writeText "gallery-dl.json" (
    builtins.toJSON {
      extractor.modules = [ "generic" ];
      extractor.generic.enabled = true;
    }
  );
in
pkgs.testers.nixosTest {
  name = "lolek-private-media";
  containers.machine = {
    imports = [
      module
      telegymModule
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
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
      galleryDownloadEnabled = true;
      maxDownloadTries = 1;
      environment = {
        LOLEK_TELEGRAM_BASE_URL = "http://127.0.0.1:5678";
        LOLEK_GALLERY_DL_CONFIG_FILE = toString galleryConfig;
      };
    };
    systemd.services.gallery-origin = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 80 --bind 127.0.0.1 --directory ${gallery}";
    };
  };
  testScript = builtins.readFile ./private-media.py + ''
    machine.wait_for_unit("gallery-origin.service")
    machine.wait_for_unit("lolek.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1/index.html >/dev/null")
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:5678/debug/bots | "
        "jq -e '.bots | any(.token_full == \"dummy-token\")' >/dev/null"
    )
    test_private_media(machine, subtest, "http://127.0.0.1:5678", "dummy-token", "http://127.0.0.1/index.html")
  '';
}
