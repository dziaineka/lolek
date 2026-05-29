{
  pkgs,
  root,
}:

let
  lib = pkgs.lib;
  beamPackages = pkgs.beam.packages.erlang_28;
  elixir = beamPackages.elixir_1_19;
  rebar3WithPlugins = beamPackages.rebar3WithPlugins {
    globalPlugins = [ beamPackages.pc ];
  };
  fetchMixDeps = beamPackages.fetchMixDeps.override {
    rebar3 = rebar3WithPlugins;
  };
  mixRelease = beamPackages.mixRelease.override {
    rebar3 = rebar3WithPlugins;
  };
  sourceFiles =
    extraFiles:
    lib.fileset.unions (
      [
        (root + "/config")
        (root + "/lib")
        (root + "/mix.exs")
        (root + "/mix.lock")
      ]
      ++ extraFiles
    );
in
{
  inherit
    beamPackages
    elixir
    rebar3WithPlugins
    fetchMixDeps
    mixRelease
    ;

  src = lib.fileset.toSource {
    inherit root;
    fileset = sourceFiles [ (root + "/rel") ];
  };

  testSrc = lib.fileset.toSource {
    inherit root;
    fileset = sourceFiles [ (root + "/test") ];
  };
}
