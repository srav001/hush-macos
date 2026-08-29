# Hush

A minimal, opinionated macOS environment built around fast window management,
a native status bar and a real Super key.

## Why Hush exists

My previous setup combined SketchyBar, AeroSpace and several separate tools and
configurations. It worked, but everything had become tangled together.

I later came across [OMACOSY](https://github.com/paulsp94/omacosy), which became
the starting point for Hush. This fork intentionally keeps much less: only the
parts I use, simplified and tuned for my Mac and workflow.

## Current setup

- AeroSpace tiling with nine workspaces
- Caps Lock as Super through Karabiner-Elements; tap it for Escape
- Native Swift bar with workspaces, brightness, volume, battery and clock
- Ghostty launched with `Super+Enter`
- Native macOS fullscreen and trackpad Space gestures
- Automatic light and dark bar colours matching my Codex themes

There are no focused-window borders, focus-follows-mouse, custom trackpad
hooks, workspace overview, weather, media, Wi-Fi, Bluetooth, wallpaper or
theme services. The bar has no network access or telemetry.

This first version leaves existing Ghostty, Tinycast and shell configuration
untouched. They will become part of the wider Hush environment separately.

## Requirements

- Apple silicon
- macOS 26 or newer
- Homebrew
- Apple Command Line Tools

## Install

```sh
git clone https://github.com/srav001/hush-macos.git ~/.local/share/hush
cd ~/.local/share/hush
./install.sh
```

The installer:

1. Installs AeroSpace and Karabiner-Elements when absent.
2. Backs up and installs their minimal configuration.
3. Compiles and signs the native bar locally.
4. Starts one user LaunchAgent for the bar.
5. Hides Apple's menu bar on the desktop and shows it in native fullscreen.

Its manifest at `~/.local/state/hush/manifest` records everything needed to
restore the previous state.

## Permissions

Two permissions are required once:

1. Give AeroSpace access in **System Settings → Privacy & Security → Accessibility**.
2. Approve Karabiner-Elements' driver and Input Monitoring access.

The Hush bar requires no privacy permissions.

## Keybindings

Hold Caps Lock for Super. Tap it for Escape.

| Key | Action |
|---|---|
| `Super+Enter` | Open a new Ghostty window |
| `Super+W` | Close window |
| `Super+arrows` | Focus by direction |
| `Super+Shift+arrows` | Move window |
| `Super+1…9` | Switch workspace |
| `Super+Shift+1…9` | Move window and follow it |
| `Super+Tab` | Previous workspace |
| `Super+T` | Toggle floating |
| `Super+J` | Cycle tile orientation |
| `Super+F` | Native macOS fullscreen |
| `Super+-` / `Super+=` | Resize |
| `Super+R` | Enter resize mode; use `h/j/k/l` and Escape to exit |

Scroll over the brightness or volume items to adjust them. Click volume to
mute. Native trackpad gestures continue to switch macOS Spaces rather than
AeroSpace workspaces.

## Uninstall

```sh
cd ~/.local/share/hush
./uninstall.sh
```

Only changes recorded by the installer are removed. Previous AeroSpace and
Karabiner configuration is restored.

## Credits

Hush is derived from [OMACOSY](https://github.com/paulsp94/omacosy) and uses
[AeroSpace](https://github.com/nikitabobko/AeroSpace) and
[Karabiner-Elements](https://karabiner-elements.pqrs.org).

MIT licensed. The original and modification notices are preserved in
[LICENSE](LICENSE).
