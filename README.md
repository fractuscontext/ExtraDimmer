# ExtraDimmer 🌟

**Make your screen even dimmer. No Extra Features. No Bloat.**

## How to use

Click the ✩ icon in the menu bar. Drag the slider. That's it.

![demo](./docs/demo.gif)

*Note: The GIF might look like we're just drawing a black sqaure on the screen, but in fact it is dimming the entire display using gamma curve (NOT as the GIF shown).*

## Installation

### Option A: Direct Download (For Normal Humans)

[![Download Latest Release](https://img.shields.io/github/v/release/fractuscontext/ExtraDimmer?style=for-the-badge&label=Download%20DMG&color=black)](https://github.com/fractuscontext/ExtraDimmer/releases/latest)

1. Download the latest `.dmg` from the [Releases tab](https://github.com/fractuscontext/ExtraDimmer/releases/latest).
2. Open it and drag `ExtraDimmer.app` into your `Applications` folder.
3. Open it, click the ✩ in the menu bar, and you're done.

### Option B: Nix Flakes + Home Manager (For the Ascended)

**1. Add the input to your `flake.nix`:**

```nix
inputs = {
  # ... your other inputs ...
  extraDimmer = {
    url = "github:fractuscontext/ExtraDimmer";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
```

**2. Pass it via `extraSpecialArgs` to Home Manager in your outputs:**

```nix
home-manager.extraSpecialArgs = {
  inherit extraDimmer; # plus your username, pkgs, etc.
};
```

**3. Add it to your Home Manager `packages` list:**

```nix
{ pkgs, extraDimmer, ... }:

{
  home.packages = [
    # ... your other packages ...
    extraDimmer.packages.${pkgs.system}.default
  ];
}
```

## How It Works

Dimmer lives purely in your menu bar. Click the ✩ icon, and you get two sliders:

1. **Hardware Brightness:** Talks directly to your built-in Apple display to adjust the backlight.
2. **Software Dimmer:** An exponential dimming curve that applies a screen overlay for external monitors (or to let you dim *below* 0% hardware backlight).

## How does it compare to other "DimmerApps"?

- **No excessive permissions** (unlike L____)
- **Simple and absolutely no bloated features** (unlike L____)
- **Truly Open Source:** The GitHub repo contains every single line of code already (unlike L____)
- **100% Free with no "hidden paid features"** (unlike L____)
- **Not "fake" open source, again** (unlike L____)
- **Stupidly simple code:** The codebase is a single file. It's so simple even my mama can understand it (unlike L____)

*Sadly, **DDC/CI (external monitors) isn't supported**. But maybe the real health question is: to reduce multi-screen eye strain, is dimming them actually better than good background lighting and resting?*

## Building the App

No Xcode required — the Swift Command Line Tools are enough.
Option A: Nix (recommended):

```sh
nix run ".#makeDmg"
```

Option B: Swift directly:

```sh
swift build -c release
```

*Then, `ExtraDimmer.app` will appear in the project root.*

## Special Thanks

Massive thanks to [MonitorControl](https://github.com/MonitorControl/MonitorControl) for their trail-blazing work in open-sourcing the reverse-engineered `DisplayServices` private endpoint.

## License

MIT License
