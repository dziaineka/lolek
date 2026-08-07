{
  pkgs,
  root,
  systems,
}:

let
  lib = pkgs.lib;
  mixBuilders = import ./mix-builders.nix { inherit pkgs; };
  inherit (mixBuilders) fetchMixDeps mixRelease;
  version = "5.2.2";
  mkLolek =
    {
      curl ? pkgs.curl,
      ffmpeg-full ? pkgs.ffmpeg-full,
      yt-dlp ? pkgs.yt-dlp,
      gallery-dl ? pkgs.gallery-dl,
    }:
    let
      runtimePath = lib.makeBinPath [
        curl
        ffmpeg-full
        pkgs.getconf
        yt-dlp
        gallery-dl
      ];
    in
    mixRelease {
      pname = "lolek";
      inherit version;
      src = root;

      mixFodDeps = fetchMixDeps {
        pname = "lolek-mix-deps";
        inherit version;
        src = root;
        hash = "sha256-bANjAi2rYIcmFCYk8VXpio9gqFhe+ZkG5ZKR7G9v8Xk=";
      };
      doCheck = true;
      nativeCheckInputs = [ pkgs.getconf ];
      checkPhase = ''
        runHook preCheck

        export MIX_ENV="prod"
        export MIX_HOME="$TMPDIR/mix"
        export HEX_HOME="$TMPDIR/hex"
        export MIX_DEPS_PATH="$TMPDIR/deps"
        export REBAR_GLOBAL_CONFIG_DIR="$TMPDIR/rebar3"
        export REBAR_CACHE_DIR="$TMPDIR/rebar3.cache"
        export LOLEK_BOT_TOKEN="test_token"

        mix test

        runHook postCheck
      '';
      doInstallCheck = true;
      nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
      versionCheckProgram = "${placeholder "out"}/bin/lolek";
      versionCheckProgramArg = "version";

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
in
lib.makeOverridable mkLolek { }
