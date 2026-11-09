{
  pkgs,
  systems,
}:

pkgs.buildGo127Module {
  pname = "telegym";
  version = "0.7.0";

  src = pkgs.fetchFromGitHub {
    owner = "kolomiichenko";
    repo = "telegym";
    tag = "v0.7.0";
    sha256 = "017z3r4kq0ahjadr92bm45z2i8xa9vrc5wl37k4lv7646dg96n76";
  };
  patches = [ ./media-groups.patch ];
  vendorHash = "sha256-cQ5OHD/uHT/VLLV2tKh0hyVjxQb/dzFKUgZdd7lVjqU=";
  env.GOWORK = "off";
  subPackages = [
    "cmd/telegym-mock"
    "cmd/telegym-proxy"
  ];
  ldflags = [
    "-s"
    "-w"
    "-X main.version=v0.7.0"
  ];

  checkPhase = ''
    runHook preCheck
    go test ./pkg/mock
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
