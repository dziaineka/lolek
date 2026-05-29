{ pkgs }:

pkgs.writeShellApplication {
  name = "formatter";
  runtimeInputs = [ pkgs.nixfmt-tree ];
  text = ''
    treefmt "$@"
  '';
}
