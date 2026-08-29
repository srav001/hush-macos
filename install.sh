#!/usr/bin/env bash
# Install Hush. Safe to re-run after local changes.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.local/state/hush"
MANIFEST="$STATE_DIR/manifest"
BIN_DIR="$HOME/.local/bin"
AGENT_DIR="$HOME/Library/LaunchAgents"
UID_N="$(id -u)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }
mark() { grep -qxF "$1" "$MANIFEST" 2>/dev/null || printf '%s\n' "$1" >> "$MANIFEST"; }
have() { grep -qxF "$1" "$MANIFEST" 2>/dev/null; }

[ "$(uname -s)" = Darwin ] || die "macOS is required"
[ "$(uname -m)" = arm64 ] || die "this build targets Apple silicon"
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 26 ] || die "macOS 26 or newer is required"
command -v brew >/dev/null 2>&1 || die "Homebrew is required: https://brew.sh"
command -v swiftc >/dev/null 2>&1 || die "Apple Command Line Tools are required: xcode-select --install"
[ ! -e "$HOME/.local/state/omacosy/manifest" ] || \
    die "OMACOSY appears active; uninstall it before installing Hush"

if [ ! -f "$MANIFEST" ]; then
    for owned_path in \
        "$BIN_DIR/hush-bar" \
        "$AGENT_DIR/com.srav001.hush.bar.plist"; do
        [ ! -e "$owned_path" ] && [ ! -L "$owned_path" ] || \
            die "existing unowned runtime file would be replaced: $owned_path"
    done
fi

mkdir -p "$STATE_DIR" "$BIN_DIR" "$AGENT_DIR"
touch "$MANIFEST"
chmod 700 "$STATE_DIR"
chmod 600 "$MANIFEST"

record_file() { # source path, backup name
    local source="$1" name="$2"
    have "recorded-file $name" && return
    if [ -e "$source" ] || [ -L "$source" ]; then
        cp -pPR "$source" "$STATE_DIR/$name.before"
        mark "had-file $name"
    fi
    mark "recorded-file $name"
}

record_file "$HOME/.config/aerospace/aerospace.toml" aerospace.toml
record_file "$HOME/.config/karabiner/karabiner.json" karabiner.json

record_default() { # defaults key, manifest name
    grep -q "^$2 " "$MANIFEST" && return
    if previous="$(defaults read NSGlobalDomain "$1" 2>/dev/null)"; then
        mark "$2 $previous"
    else
        mark "$2 ABSENT"
    fi
}
record_default _HIHideMenuBar menu-bar
record_default AppleMenuBarVisibleInFullscreen menu-bar-fullscreen

log "Installing AeroSpace and Karabiner"
if ! brew trust --json=v1 2>/dev/null | grep -q '"nikitabobko/tap"'; then
    brew trust --tap nikitabobko/tap
    mark "trusted-tap nikitabobko/tap"
fi
before_casks="$(brew list --cask 2>/dev/null | sort)"
before_taps="$(brew tap 2>/dev/null | sort)"
if ! brew bundle --file="$REPO_DIR/Brewfile"; then
    after_casks="$(brew list --cask 2>/dev/null | sort)"
    after_taps="$(brew tap 2>/dev/null | sort)"
    comm -13 <(printf '%s\n' "$before_casks") <(printf '%s\n' "$after_casks") |
        while IFS= read -r cask; do [ -n "$cask" ] && mark "installed-cask $cask"; done
    comm -13 <(printf '%s\n' "$before_taps") <(printf '%s\n' "$after_taps") |
        while IFS= read -r tap; do [ -n "$tap" ] && mark "installed-tap $tap"; done
    die "Homebrew did not complete; resolve the error and run install.sh again"
fi
after_casks="$(brew list --cask 2>/dev/null | sort)"
after_taps="$(brew tap 2>/dev/null | sort)"
comm -13 <(printf '%s\n' "$before_casks") <(printf '%s\n' "$after_casks") |
    while IFS= read -r cask; do [ -n "$cask" ] && mark "installed-cask $cask"; done
comm -13 <(printf '%s\n' "$before_taps") <(printf '%s\n' "$after_taps") |
    while IFS= read -r tap; do [ -n "$tap" ] && mark "installed-tap $tap"; done

log "Installing minimal configurations"
mkdir -p "$HOME/.config/aerospace" "$HOME/.config/karabiner"
cp "$REPO_DIR/config/aerospace/aerospace.toml" "$HOME/.config/aerospace/aerospace.toml"
cp "$REPO_DIR/config/karabiner/karabiner.json" "$HOME/.config/karabiner/karabiner.json"
chmod 600 "$HOME/.config/aerospace/aerospace.toml" \
    "$HOME/.config/karabiner/karabiner.json"

log "Compiling the bar"
swiftc -O -F /System/Library/PrivateFrameworks -framework DisplayServices \
    -o "$BIN_DIR/hush-bar" "$REPO_DIR/helper/bar.swift"
codesign --force --sign - --identifier com.srav001.hush.bar "$BIN_DIR/hush-bar" >/dev/null

cat > "$AGENT_DIR/com.srav001.hush.bar.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.srav001.hush.bar</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/hush-bar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
PLIST

plutil -lint "$AGENT_DIR/com.srav001.hush.bar.plist" >/dev/null

log "Starting AeroSpace"
open -a AeroSpace
sleep 1
aerospace reload-config 2>/dev/null || true

log "Starting the minimal services"
restart_agent() { # label, plist
    launchctl bootout "gui/$UID_N/$1" 2>/dev/null || true
    launchctl bootstrap "gui/$UID_N" "$2" 2>/dev/null || {
        sleep 1
        launchctl bootstrap "gui/$UID_N" "$2"
    }
    launchctl kickstart -k "gui/$UID_N/$1"
}
restart_agent com.srav001.hush.bar "$AGENT_DIR/com.srav001.hush.bar.plist"

# Karabiner's remap runs in its core service. Its menu and notification
# helpers are unnecessary after first-run approval and otherwise idle heavily.
launchctl kickstart -k "gui/$UID_N/org.pqrs.service.agent.karabiner_console_user_server" \
    2>/dev/null || true
for agent in Karabiner-Menu Karabiner-NotificationWindow; do
    if launchctl print-disabled "gui/$UID_N" 2>/dev/null |
        grep -q "\"org.pqrs.service.agent.$agent\" => true"; then
        mark "agent-was-disabled $agent"
    fi
    launchctl bootout "gui/$UID_N/org.pqrs.service.agent.$agent" 2>/dev/null || true
    launchctl disable "gui/$UID_N/org.pqrs.service.agent.$agent" 2>/dev/null || true
done
pkill -f 'Karabiner-Menu|Karabiner-NotificationWindow' 2>/dev/null || true

defaults write NSGlobalDomain _HIHideMenuBar -bool true
defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool true
killall cfprefsd 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

if ! launchctl list 2>/dev/null | grep -q org.pqrs.service.agent.karabiner_console_user_server; then
    open -a Karabiner-Elements
fi

cat <<'EOF'

Hush installed. One-time permissions:
  1. AeroSpace: Privacy & Security -> Accessibility
  2. Karabiner-Elements: approve its driver and Input Monitoring

Existing Ghostty, Tinycast, shell configuration and native trackpad gestures were not changed.
Uninstall: ./uninstall.sh
EOF
