{
  description = " Run a Shadertoy-compatible shader as an animated wallpaper on Wayland ";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    zig2nix.url = "github:Cloudef/zig2nix";
    zig2nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    zig2nix,
    nixpkgs,
    ...
  }: let
    flake-utils = zig2nix.inputs.flake-utils;
  in (flake-utils.lib.eachDefaultSystem (system: let
    pkgs = nixpkgs.legacyPackages.${system};

    zigv = removeAttrs (pkgs.callPackage ./zig-version.nix
      {
        zigHook = env.zigHook;
        zigBin = pkgs.callPackage (builtins.toPath (zig2nix.outPath + "/src/zig/bin.nix"));
      }) ["override" "overrideAttrs" "overrideDerivation"];

    env = zig2nix.outputs.zig-env.${system} {
      zig = zigv.master;
    };

    # Deps that need to be present when we run 'zig build'
    zigBuildDeps = with env.pkgs; [
      wayland-protocols
      wayland-scanner
    ];
  in
    with env.pkgs.lib; rec {
      # Produces clean binaries meant to be ship'd outside of nix
      # nix build .#foreign
      packages.foreign = env.package {
        src = cleanSource ./.;

        # Packages required for compiling
        nativeBuildInputs = zigBuildDeps;

        # Packages required for linking
        buildInputs = with env.pkgs; [
          wayland
          libglvnd
          # Required to run under NixOS.
          autoPatchelfHook
        ];

        # We're linking against stuff like libwayland-client.so so we need the system
        # libc
        zigPreferMusl = false;
      };

      # nix build .
      packages.default = packages.foreign.override (attrs: {
        nativeBuildInputs = attrs.nativeBuildInputs;

        # Executables required for runtime
        # These packages will be added to the PATH
        zigWrapperBins = with env.pkgs; [];

        # Libraries required for runtime
        # These packages will be added to the LD_LIBRARY_PATH
        zigWrapperLibs = attrs.buildInputs or [];
      });

      # For bundling with nix bundle for running outside of nix
      # example: https://github.com/ralismark/nix-appimage
      apps.bundle = {
        type = "app";
        program = "${packages.foreign}/bin/papertoy";
      };

      # nix run .
      apps.default = env.app zigBuildDeps "zig build run -- \"$@\"";

      # nix run .#build
      apps.build = env.app zigBuildDeps "zig build \"$@\"";

      # nix run .#zig2nix
      apps.zig2nix = env.app zigBuildDeps "zig2nix \"$@\"";

      # nix develop
      devShells.default = env.mkShell {
        # Packages required for compiling, linking and running
        # Libraries added here will be automatically added to the LD_LIBRARY_PATH and PKG_CONFIG_PATH
        nativeBuildInputs =
          []
          ++ packages.default.nativeBuildInputs
          ++ packages.default.buildInputs
          ++ packages.default.zigWrapperBins
          ++ packages.default.zigWrapperLibs;
      };
    }));
}
