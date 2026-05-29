{
  pkgs,
  root,
  systems,
}:

let
  common = import ./common.nix { inherit pkgs root; };
  lib = pkgs.lib;
  runtimePath = lib.makeBinPath [
    pkgs.curl
    pkgs.ffmpeg
    pkgs.yt-dlp
  ];
in
rec {
  lolek = common.mixRelease {
    pname = "lolek";
    version = "1.8.1";
    inherit (common) elixir src;

    mixFodDeps = common.fetchMixDeps {
      pname = "lolek-mix-deps";
      version = "1.8.1";
      src = root;
      inherit (common) elixir;
      hash = "sha256-pdh+PiriuRixsEw2Mvjop3kTRyUo60mWdcB3PWhkqK8=";
    };

    postInstall = ''
      wrapProgram "$out/bin/lolek" \
        --run 'export RELEASE_COOKIE="''${RELEASE_COOKIE:-lolek}"' \
        --prefix PATH : ${runtimePath}
    '';

    meta = {
      description = "Telegram bot that downloads media from URLs and uploads it to Telegram";
      homepage = "https://github.com/skaborik/lolek_bot";
      license = lib.licenses.mit;
      mainProgram = "lolek";
      platforms = systems;
    };
  };

  default = lolek;
}
