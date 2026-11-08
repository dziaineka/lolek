# Telegym, the Telegram Bot API mock used by the integration tests.
#
# Upstream has no Nix packaging, and v0.7.0 needs Go 1.27, which the pinned
# nixpkgs release does not have. This package uses the static release binaries.
# The hashes are from the checksums.txt file of the release.
{
  pkgs,
  systems,
}:

let
  version = "0.7.0";
  assets = {
    x86_64-linux = {
      name = "linux_amd64";
      sha256 = "5d100ce619e9eefa1dec9d1585a9297524ca73fcb9444106407cc9eb19f0076a";
    };
    aarch64-linux = {
      name = "linux_arm64";
      sha256 = "5459c2bec9697ef5789940b205b1973e0c319043026ab906f07a122889f001e6";
    };
    x86_64-darwin = {
      name = "darwin_amd64";
      sha256 = "36c63dc4d38f1955b3296ce26140e2bd4118080c4c028f98b325bd27174bfc10";
    };
    aarch64-darwin = {
      name = "darwin_arm64";
      sha256 = "aa8f2c429f534d84dd99356cb8de4914e8b6de5d8456fcaabfee07da3d9fce45";
    };
  };
  asset = assets.${pkgs.stdenv.hostPlatform.system};
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "telegym";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/kolomiichenko/telegym/releases/download/v${version}/telegym_v${version}_${asset.name}.tar.gz";
    inherit (asset) sha256;
  };

  sourceRoot = "telegym_v${version}_${asset.name}";

  installPhase = ''
    runHook preInstall
    install -Dm755 telegym-mock telegym-proxy -t "$out/bin"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/telegym-mock" -version | grep -F "v${version}"
  '';

  meta = {
    description = "Mock and proxy servers for the Telegram Bot API";
    homepage = "https://github.com/kolomiichenko/telegym";
    license = pkgs.lib.licenses.mit;
    mainProgram = "telegym-mock";
    platforms = systems;
    sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
  };
}
