{
  pkgs,
  module,
  package,
}:

pkgs.testers.nixosTest {
  name = "lolek-service";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ module ];

      services.lolek = {
        enable = true;
        inherit package;
        environmentFile = pkgs.writeText "lolek.env" ''
          LOLEK_BOT_TOKEN=dummy-token
        '';
      };

      # This test validates deployment wiring without contacting Telegram.
      systemd.services.lolek.wantedBy = lib.mkForce [ ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    machine.succeed("getent passwd lolek")
    machine.succeed("getent group lolek")
    machine.succeed("test -d /var/lib/lolek")
    machine.succeed("test -d /var/lib/lolek/downloads")
    machine.succeed("test $(stat -c %U /var/lib/lolek/downloads) = lolek")
    machine.succeed("test $(stat -c %G /var/lib/lolek/downloads) = lolek")
    machine.succeed("su -s /bin/sh lolek -c 'test -w /var/lib/lolek/downloads'")

    machine.succeed("systemctl cat lolek.service | grep 'ExecStart=.*lolek start'")
    machine.succeed("systemctl cat lolek.service | grep 'EnvironmentFile=.*lolek.env'")
    machine.succeed("systemctl show lolek.service -p Environment | grep 'LOLEK_DOWNLOAD_DIR_PATH=/var/lib/lolek/downloads'")
  '';
}
