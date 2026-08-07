{ pkgs }:

let
  beamPackages = pkgs.beam.packages.erlang_29;
  elixir = beamPackages.elixir_1_20;

  # Mix coordinates compilation with local TCP sockets, but Darwin's Nix
  # sandbox denies listeners by default. Permit local networking for every
  # Mix derivation so its compilation locks and event pubsub keep working.
  withMixInputs =
    attrs:
    attrs
    // {
      inherit elixir hex;
      __darwinAllowLocalNetworking = true;
    };

  baseHex = beamPackages.hex.override { inherit elixir; };
  hex = baseHex.overrideAttrs (_: {
    __darwinAllowLocalNetworking = true;
  });
  rebar3WithPlugins = beamPackages.rebar3WithPlugins {
    globalPlugins = [ beamPackages.pc ];
  };
  fetchMixDepsBuilder = beamPackages.fetchMixDeps.override {
    rebar3 = rebar3WithPlugins;
  };
  mixReleaseBuilder = beamPackages.mixRelease.override {
    makeWrapper = pkgs.makeBinaryWrapper;
    rebar3 = rebar3WithPlugins;
  };
in
{
  fetchMixDeps = attrs: fetchMixDepsBuilder (withMixInputs attrs);
  mixRelease = attrs: mixReleaseBuilder (withMixInputs attrs);
}
