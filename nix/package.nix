{
  pkgs,
  root,
  systems,
  telegym,
}:

let
  lolek = import ./pkgs/lolek.nix {
    inherit pkgs root systems;
  };
  corpusPackages = import ./pkgs/corpus.nix {
    inherit
      pkgs
      root
      systems
      lolek
      telegym
      ;
  };
in
corpusPackages
// {
  inherit lolek;
  default = lolek;
}
