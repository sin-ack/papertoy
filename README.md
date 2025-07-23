# Papertoy

Run a Shadertoy-compatible shader as an animated wallpaper on Wayland. Requires
running a wlroots-compatible Wayland compositor.

## Showcase

https://github.com/user-attachments/assets/8d6ae569-8fed-4ae5-aa11-4a3db6d13167

Shader: Balatro main menu background shader *(not publicly available)*

![Papertoy running the "Seascape" shader](https://github.com/user-attachments/assets/010e225e-0952-4511-a1cf-715389ebf907)

Shader: *Seascape* by TDM - https://www.shadertoy.com/view/Ms2SD1

![Papertoy running the "Auroras" shader](https://github.com/user-attachments/assets/6db0bcd8-7d63-4720-9596-8b14114c158b)

Shader: *Auroras* by Nimitz - https://www.shadertoy.com/view/XtGGRt

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
