# Papertoy

[![justforfunnoreally.dev badge](https://img.shields.io/badge/justforfunnoreally-dev-9ff)](https://justforfunnoreally.dev)

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

You'll most likely have these installed if you have a Wayland compositor anyway.

- Debian and variants: `libwayland-client0 libwayland-egl1 libegl1 libglvnd0 libffi8`
- Gentoo: `dev-util/wayland media-libs/glvnd dev-libs/libffi`

## Install

Either [download the latest release](https://github.com/sin-ack/papertoy/releases/latest) or follow the [build instructions below](#build).

Place `papertoy` somewhere in your `PATH` (e.g. `.local/bin`).

Once I'm happy with the stability I'll probably go for system packages.

## Usage

Run the binary with the path to a Shadertoy shader as an argument:
```console
$ zig-out/bin/papertoy /path/to/shader.glsl
```

> [!IMPORTANT]
> Currently, only shaders that don't use any channels are supported. This is
> being worked on.

### Options

- `--output <config>`: Configure individual outputs. Can be specified multiple times.

  **Format:** `id=<name>[,resolution=<WxH>][,frame-rate=<fps>]`

  For compatibility with older versions, `--output <name>` is also accepted as shorthand for `--output "id=<name>"`.

  **Parameters:**
  - `id`: The name of the output (e.g., `DP-1`, `HDMI-A-1`). Use your compositor's output list command to find yours (e.g., `niri msg outputs`, `swaymsg -t get_outputs`, `hyprctl monitors`).
  - `resolution`: Force a specific positive logical resolution (e.g., `1920x1080`).
  - `frame-rate`: Limit the frame rate (e.g., `30`, `60`). Defaults to compositor frame callbacks.

- `--frame-rate <fps>`: Set the default frame rate for selected outputs. Per-output `frame-rate` values override this.
- `--resolution <WxH>`: Set the default positive logical resolution for selected outputs. Per-output `resolution` values override this.

### Configuration Examples

**1. Performance Mode (Recommended for 4K)**
Render at half resolution (1080p on 4K) to save GPU power, but keep the window fullscreen.
```console
$ papertoy shader.glsl --output "id=HDMI-A-1,resolution=1920x1080"
```

**2. Multi-Monitor Setup**
Configure a high-refresh main monitor and a slower secondary monitor.
```console
$ papertoy shader.glsl \
    --output "id=DP-1,frame-rate=144" \
    --output "id=HDMI-A-1,resolution=1920x1080,frame-rate=30"
```

**3. Custom Resolution**
Force a specific aspect ratio or size.
```console
$ papertoy shader.glsl --output "id=DP-1,resolution=800x600"
```

**4. Compatibility Options**
Older single-output invocations still work.
```console
$ papertoy shader.glsl --output DP-1 --frame-rate 30 --resolution 1920x1080
```

## Build

### Nix

1. `nix run .`
2. There is no second step.

You can add the flake to your profile with: `nix profile install github:sin-ack/papertoy/<version>`

### Bare metal

#### Dependencies

- Zig 0.15.2
- `libwayland`
  - Debian and variants: `libwayland-dev`
  - Gentoo: `dev-util/wayland`
- `libglvnd`
  - Debian and variants: `libglvnd-dev`
  - Gentoo: `media-libs/glvnd`

#### Steps

1. Install the listed dependencies above.
2. Clone the repository.
3. Run `zig build -Doptimize=ReleaseFast`

The binary will be located at `zig-out/bin/papertoy`.

## License

Copyright (c) 2025, sin-ack. Released under the GNU General Public License, version 3.

The Shadertoy preamble is from the Ghostty project. Copyright (c) 2024 Mitchell Hashimoto, License: MIT

The wlr-layer-shell-unstable-v1 protocol is from the wlr-protocols project. Copyright (c) 2017 Drew DeVault, License: MIT
