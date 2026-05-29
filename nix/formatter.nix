{ pkgs }:

pkgs.writeShellApplication {
  name = "formatter";
  runtimeInputs = [
    pkgs.findutils
    pkgs.git
    pkgs.nixfmt-tree
    pkgs.ruff
  ];
  text = ''
    treefmt "$@"
    git ls-files -z -- '*.py' '**/*.py' | xargs -0 -r ruff format
    git ls-files -z -- '*.py' '**/*.py' | xargs -0 -r ruff check
  '';
}
