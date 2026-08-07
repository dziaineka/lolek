{
  pkgs,
  src,
  systems,
}:

pkgs.buildGoModule {
  pname = "telegym";
  version = "0.1.0-unstable-2026-08-02";
  inherit src;

  vendorHash = "sha256-ZhVfO2FPHpEHcptSJI3l6P0QVDBub7CPEFQB2GhD0eI=";
  modBuildPhase = ''
    runHook preBuild

    export GIT_SSL_CAINFO="$NIX_SSL_CERT_FILE"
    go work vendor
    mkdir -p vendor

    runHook postBuild
  '';

  subPackages = [
    "cmd/telegym-mock"
    "cmd/telegym-proxy"
  ];

  doCheck = true;
  __darwinAllowLocalNetworking = true;
  checkPhase = ''
    runHook preCheck

    export GOFLAGS=''${GOFLAGS//-trimpath/}
    go test -timeout 5m ./...
    (cd pkg/xk6 && go test -timeout 5m ./...)

    runHook postCheck
  '';

  meta = {
    description = "Mock and proxy servers for the Telegram Bot API";
    homepage = "https://github.com/kolomiichenko/telegym";
    license = pkgs.lib.licenses.mit;
    mainProgram = "telegym-mock";
    platforms = systems;
  };
}
