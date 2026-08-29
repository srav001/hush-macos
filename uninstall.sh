#!/usr/bin/env bash
# Remove only changes made by Hush.
set -uo pipefail

STATE_DIR="$HOME/.local/state/hush"
MANIFEST="$STATE_DIR/manifest"
BIN_DIR="$HOME/.local/bin"
AGENT_DIR="$HOME/Library/LaunchAgents"
UID_N="$(id -u)"

log() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
have() { [ -f "$MANIFEST" ] && grep -qxF "$1" "$MANIFEST"; }

[ -f "$MANIFEST" ] || {
    printf 'No Hush installation manifest found. Nothing changed.\n'
    exit 0
}

log "Stopping the bar"
launchctl bootout "gui/$UID_N/com.srav001.hush.bar" 2>/dev/null || true
rm -f "$AGENT_DIR/com.srav001.hush.bar.plist" "$BIN_DIR/hush-bar"
rm -f "/tmp/hush-bar-ws-$UID_N"

restore_file() { # destination, backup name
    local destination="$1" name="$2"
    have "recorded-file $name" || return
    rm -f "$destination"
    if have "had-file $name" && [ -e "$STATE_DIR/$name.before" ]; then
        mkdir -p "$(dirname "$destination")"
        cp -pPR "$STATE_DIR/$name.before" "$destination"
    fi
}

log "Restoring previous configurations"
restore_file "$HOME/.config/aerospace/aerospace.toml" aerospace.toml
restore_file "$HOME/.config/karabiner/karabiner.json" karabiner.json
rmdir "$HOME/.config/aerospace" "$HOME/.config/karabiner" 2>/dev/null || true

for agent in Karabiner-Menu Karabiner-NotificationWindow; do
    if have "agent-was-disabled $agent"; then
        launchctl disable "gui/$UID_N/org.pqrs.service.agent.$agent" 2>/dev/null || true
    else
        launchctl enable "gui/$UID_N/org.pqrs.service.agent.$agent" 2>/dev/null || true
    fi
done
launchctl kickstart -k "gui/$UID_N/org.pqrs.service.agent.karabiner_console_user_server" \
    2>/dev/null || true

restore_default() { # defaults key, manifest name
    local previous
    previous="$(grep "^$2 " "$MANIFEST" | head -1 | cut -d' ' -f2-)"
    if [ "$previous" = ABSENT ]; then
        defaults delete NSGlobalDomain "$1" 2>/dev/null || true
    elif [ -n "$previous" ]; then
        defaults write NSGlobalDomain "$1" -bool "$previous"
    fi
}
restore_default _HIHideMenuBar menu-bar
restore_default AppleMenuBarVisibleInFullscreen menu-bar-fullscreen
killall cfprefsd 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

if have "installed-cask aerospace"; then
    osascript -e 'quit app "AeroSpace"' 2>/dev/null || true
elif command -v aerospace >/dev/null 2>&1; then
    aerospace reload-config 2>/dev/null || true
fi

if grep -q '^installed-cask ' "$MANIFEST"; then
    log "Removing Homebrew casks added by this installer"
    while IFS= read -r cask; do
        [ -n "$cask" ] && brew uninstall --cask "$cask" 2>/dev/null || true
    done < <(sed -n 's/^installed-cask //p' "$MANIFEST")
fi

if grep -q '^installed-tap ' "$MANIFEST"; then
    while IFS= read -r tap; do
        [ -n "$tap" ] && brew untap "$tap" 2>/dev/null || true
    done < <(sed -n 's/^installed-tap //p' "$MANIFEST")
fi
if have "trusted-tap nikitabobko/tap"; then
    brew untrust --tap nikitabobko/tap 2>/dev/null || true
fi

rm -rf "$STATE_DIR"
printf '\nUninstalled. Ghostty, Tinycast, shell files and native trackpad gestures were untouched.\n'
