# Adapted from: https://github.com/Cloudef/zig2nix/blob/master/src/zig/versions.nix
# SPDX-License-Identifier: MIT
{
  zigHook,
  zigBin,
}: let
  meta-master = {
    version = "0.15.0-dev.1149+4e6a04929";
    date = "2025-07-21";
    docs = "https://ziglang.org/documentation/master/";
    stdDocs = "https://ziglang.org/documentation/master/std/";

    x86_64-linux = {
      tarball = "https://ziglang.org/builds/zig-x86_64-linux-0.15.0-dev.1149+4e6a04929.tar.xz";
      shasum = "84faac35b5632b9b4204ec428839ba15d8bfba920c5342bea32d63d9df55c301";
    };

    aarch64-linux = {
      tarball = "https://ziglang.org/builds/zig-aarch64-linux-0.15.0-dev.1149+4e6a04929.tar.xz";
      shasum = "f800b43bb70e0e2d909986f9992e600736e83cc63b56c92f5a6a37aad8fab3bc";
    };
  };
in {
  master = zigBin {
    inherit zigHook;
    release = meta-master;
  };
}
