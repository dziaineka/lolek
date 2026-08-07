{
  pkgs,
  root,
  systems,
  telegymSrc,
}:

let
  lolek = import ./pkgs/lolek.nix {
    inherit pkgs root systems;
  };
  telegym = import ./pkgs/telegym.nix {
    inherit pkgs systems;
    src = telegymSrc;
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
  inherit lolek telegym;
  default = lolek;
}
