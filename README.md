# Hush

A quiet, minimal macOS environment with tiled workspaces, a native bar,
Control-based shortcuts, Ghostty and Tinycast.

## Why Hush exists

My previous setup combined SketchyBar, AeroSpace and several separate tools and
configurations. It worked, but everything had become tangled together.

I later came across [OMACOSY](https://github.com/paulsp94/omacosy), which became
the starting point for Hush. This fork intentionally keeps much less: only the
parts I use, simplified and tuned for my Mac and workflow.

## Current setup

- AeroSpace tiling with nine workspaces
- Physical Control as the window-management modifier
- Native Swift bar with workspaces, brightness, volume, battery and clock
- Ghostty with RobotoMono Nerd Font, launched with `Control+Enter`
- Tinycast on `Command+Space`, replacing Spotlight
- Codex CLI, OpenCode and Neovim
- Native macOS fullscreen and trackpad Space gestures
- Automatic light and dark bar colours matching my Codex themes

Hush deliberately has no focused-window borders, focus-follows-mouse, custom
trackpad hooks, workspace overview, weather, media, Wi-Fi, Bluetooth, wallpaper
or theme services. The bar has no network access or telemetry.

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

The installer is safe to re-run. It converges the machine toward the same
setup without reinstalling applications unnecessarily:

1. Reuses existing supported apps or CLI tools, even without Homebrew receipts.
2. Repairs Homebrew-managed apps whose application bundle was moved or removed.
3. Installs only missing apps, then atomically applies the Hush configurations.
4. Compiles and signs the small native bar locally, then starts one LaunchAgent.
5. Repairs Tinycast, Spotlight and menu-bar settings on every run.

Its manifest at `~/.local/state/hush/manifest` records everything needed to
restore the previous state. If an install or uninstall is interrupted, the
recovery data remains in place for the next run.

## Permissions

One permission is required once:

1. Give AeroSpace access in **System Settings → Privacy & Security → Accessibility**.

The Hush bar requires no privacy permissions.

## Keybindings

| Key | Action |
|---|---|
| `Control+Enter` | Open a new Ghostty window |
| `Control+w` | Close the focused window |
| `Control+q` | Quit the current app |
| `Control+arrows` | Focus by direction |
| `Control+Shift+arrows` | Move window |
| `Control+1…9` | Switch workspace |
| `Control+Shift+1…9` | Move window and follow it |
| `Control+Tab` | Previous workspace |
| `Control+t` | Toggle floating |
| `Control+j` | Cycle tile orientation |
| `Control+f` | Native macOS fullscreen |
| `Control+-` / `Control+=` | Resize |
| `Control+r` | Enter resize mode; use `h/j/k/l` and Escape to exit |

Scroll over the brightness or volume items to adjust them. Click volume to
mute. Native trackpad gestures continue to switch macOS Spaces rather than
AeroSpace workspaces.

## Uninstall

```sh
cd ~/.local/share/hush
./uninstall.sh
```

Only changes recorded by the installer are removed. Previous AeroSpace and
Ghostty configuration, Tinycast preferences, Spotlight shortcuts and menu-bar
settings are restored. Apps that already existed are not removed.

## Structure

- `Brewfile` declares five casks and two command-line formulae.
- `config/` contains only the two managed app configurations.
- `helper/bar.swift` is the single native bar process.
- `scripts/lib.sh` owns backup, atomic replacement and restoration primitives.
- `scripts/verify.sh` and `scripts/test-installer.sh` verify the build and recovery behavior.

## Credits

Hush is derived from [OMACOSY](https://github.com/paulsp94/omacosy) and uses
[AeroSpace](https://github.com/nikitabobko/AeroSpace).

MIT licensed. The original and modification notices are preserved in
[LICENSE](LICENSE).

Built with intentional guidance from a human.
