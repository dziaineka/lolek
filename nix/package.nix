{
  pkgs,
  root,
  systems,
}:

let
  common = import ./common.nix { inherit pkgs root; };
  lib = pkgs.lib;
  version = "1.8.1";
  runtimePath = lib.makeBinPath [
    pkgs.curl
    pkgs.ffmpeg-full
    pkgs.yt-dlp
  ];
in
rec {
  lolek = common.mixRelease {
    pname = "lolek";
    inherit version;
    inherit (common) elixir src;

    mixFodDeps = common.fetchMixDeps {
      pname = "lolek-mix-deps";
      inherit version;
      src = root;
      inherit (common) elixir;
      hash = "sha256-pdh+PiriuRixsEw2Mvjop3kTRyUo60mWdcB3PWhkqK8=";
    };

    postInstall = ''
      cat >> "$out/releases/${version}/env.sh" <<'EOF'

      export RELEASE_COOKIE="''${RELEASE_COOKIE:-lolek}"
      export RELEASE_PROG="lolek"
      export PATH="${runtimePath}:$PATH"
      EOF
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
