# Papertoy

Run a Shadertoy-compatible shader as an animated wallpaper on Wayland. Requires
running a wlroots-compatible Wayland compositor.

## Dependencies

- Zig master (tested version: `0.15.0-dev.1149+4e6a04929`)
- `libwayland` (`libwayland-dev`, `dev-util/wayland` etc.)
- `libglvnd` (`libglvnd-dev`, `media-libs/glvnd` etc.)

## Build

1. Install the listed dependencies above.
2. Clone the repository.
3. Run `zig build -Doptimize=ReleaseFast`

The binary will be located at `zig-out/bin/papertoy`.

## Usage

Run the binary with the path to a Shadertoy shader as an argument:
```console
$ zig-out/bin/papertoy /path/to/shader.glsl
```

Options:
- `--output <id>`: Render to this Wayland output index (default: `0`)

## License

Copyright (c) 2025, sin-ack. Released under the GNU General Public License, version 3.

The Shadertoy preamble is from the Ghostty project. Copyright (c) 2024 Mitchell Hashimoto, License: MIT

The wlr-layer-shell-unstable-v1 protocol is from the wlr-protocols project. Copyright (c) 2017 Drew DeVault, License: MIT
