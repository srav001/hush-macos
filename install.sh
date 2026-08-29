#!/usr/bin/env bash
# Install Hush. Safe to re-run to repair or update the environment.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

[ "$(uname -s)" = Darwin ] || die "macOS is required"
[ "$(uname -m)" = arm64 ] || die "this build targets Apple silicon"
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 26 ] || die "macOS 26 or newer is required"
command -v brew >/dev/null 2>&1 || die "Homebrew is required: https://brew.sh"
command -v swiftc >/dev/null 2>&1 || die "Apple Command Line Tools are required: xcode-select --install"
[ ! -e "$HOME/.local/state/omacosy/manifest" ] ||
    die "OMACOSY appears active; uninstall it before installing Hush"

if [ ! -f "$MANIFEST" ]; then
    for owned_path in "$BAR_BIN" "$BAR_PLIST"; do
        [ ! -e "$owned_path" ] && [ ! -L "$owned_path" ] ||
            die "existing unowned runtime file would be replaced: $owned_path"
    done
fi

mkdir -p "$STATE_DIR" "$BIN_DIR" "$AGENT_DIR"
touch "$MANIFEST"
chmod 700 "$STATE_DIR"
chmod 600 "$MANIFEST"

# Preserve backups created by the first Hush installer while migrating its
# old inline default records to the recoverable file format.
migrate_default() { # legacy manifest name
    local name="$1" previous
    have "recorded-default $name" && return
    previous="$(sed -n "s/^$name //p" "$MANIFEST" | head -1)"
    [ -n "$previous" ] || return 0
    if [ "$previous" != ABSENT ]; then
        printf '%s\n' "$previous" > "$STATE_DIR/$name.before"
        mark "had-default $name"
    fi
    mark "recorded-default $name"
}
migrate_default menu-bar
migrate_default menu-bar-fullscreen

while IFS='|' read -r name _ destination _; do
    record_file "$destination" "$name"
done < <(config_rows)

record_default NSGlobalDomain _HIHideMenuBar menu-bar
record_default NSGlobalDomain AppleMenuBarVisibleInFullscreen menu-bar-fullscreen
record_default com.tinycast.app showInMenuBar tinycast-menu
record_default com.tinycast.app compactMode tinycast-compact
record_default com.tinycast.app popToRootTimeout tinycast-timeout
record_default com.tinycast.app hotkey.togglePalette tinycast-hotkey
record_spotlight_shortcut 64
record_spotlight_shortcut 65

log "Installing or repairing the required applications"
if ! brew tap 2>/dev/null | grep -qxF nikitabobko/tap; then
    mark "installed-tap nikitabobko/tap"
fi
if ! brew trust --json=v1 2>/dev/null | grep -q '"nikitabobko/tap"'; then
    mark "trusted-tap nikitabobko/tap"
    brew trust --tap nikitabobko/tap
fi

skip_casks=""
for specification in "ghostty|Ghostty|com.mitchellh.ghostty" "tinycast|Tinycast|com.tinycast.app"; do
    IFS='|' read -r cask app bundle_id <<< "$specification"
    if ! brew_has_cask "$cask" && app_bundle_path "$app" "$bundle_id" >/dev/null; then
        skip_casks="${skip_casks:+$skip_casks }$cask"
        log "Reusing existing $app"
    fi
done

while IFS= read -r cask; do
    if ! brew_has_cask "$cask" && [[ " $skip_casks " != *" $cask "* ]]; then
        # Ownership intent is durable before Homebrew mutates the machine.
        mark "installed-cask $cask"
    fi
done < <(brew bundle list --cask --file="$REPO_DIR/Brewfile")

HOMEBREW_BUNDLE_CASK_SKIP="$skip_casks" \
    brew bundle --no-upgrade --file="$REPO_DIR/Brewfile" ||
    die "Homebrew did not complete; resolve the error and run install.sh again"

for specification in "ghostty|Ghostty|com.mitchellh.ghostty" "tinycast|Tinycast|com.tinycast.app"; do
    IFS='|' read -r cask app bundle_id <<< "$specification"
    if brew_has_cask "$cask" && ! app_bundle_path "$app" "$bundle_id" >/dev/null; then
        log "Repairing missing $app application bundle"
        brew reinstall --cask "$cask"
    fi
    app_bundle_path "$app" "$bundle_id" >/dev/null || die "$app is installed but cannot be found"
done

ghostty_app="$(app_bundle_path Ghostty com.mitchellh.ghostty)"
"$ghostty_app/Contents/MacOS/ghostty" +validate-config \
    --config-file="$REPO_DIR/config/ghostty/config"
jq empty "$REPO_DIR/config/karabiner/karabiner.json"

log "Installing configurations atomically"
while IFS='|' read -r _ source destination mode; do
    replace_file "$source" "$destination" "$mode"
done < <(config_rows)

tinycast_repair=false
default_equals com.tinycast.app showInMenuBar bool 0 || tinycast_repair=true
default_equals com.tinycast.app compactMode bool 0 || tinycast_repair=true
default_equals com.tinycast.app popToRootTimeout int 0 || tinycast_repair=true
tinycast_hotkey='{"combo":{"_0":{"carbonModifiers":256,"carbonKeyCode":49}}}'
default_equals com.tinycast.app hotkey.togglePalette string "$tinycast_hotkey" || tinycast_repair=true
if $tinycast_repair; then
    osascript -e 'quit app "Tinycast"' 2>/dev/null || true
    write_default com.tinycast.app showInMenuBar bool false
    write_default com.tinycast.app compactMode bool false
    write_default com.tinycast.app popToRootTimeout int 0
    write_default com.tinycast.app hotkey.togglePalette string "$tinycast_hotkey"
fi

# Command+Space belongs to Tinycast; preserve and disable only Spotlight's two
# conflicting entries instead of replacing the whole shortcuts domain.
update_spotlight_shortcut 64 \
    '{"enabled":false,"value":{"type":"standard","parameters":[32,49,1048576]}}'
update_spotlight_shortcut 65 \
    '{"enabled":false,"value":{"type":"standard","parameters":[32,49,1572864]}}'

write_default NSGlobalDomain _HIHideMenuBar bool true
write_default NSGlobalDomain AppleMenuBarVisibleInFullscreen bool true

log "Compiling the native bar"
bar_temporary="$(mktemp "$BIN_DIR/.hush-bar.XXXXXX")"
plist_temporary=""
cleanup() {
    [ -z "$bar_temporary" ] || rm -f "$bar_temporary"
    [ -z "$plist_temporary" ] || rm -f "$plist_temporary"
}
trap cleanup EXIT
swiftc -O -o "$bar_temporary" "$REPO_DIR/helper/bar.swift"
chmod 755 "$bar_temporary"
codesign --force --sign - --identifier "$BAR_LABEL" "$bar_temporary" >/dev/null
codesign --verify --strict "$bar_temporary"
mv -f "$bar_temporary" "$BAR_BIN"
bar_temporary=""

plist_temporary="$(mktemp "$AGENT_DIR/.hush-bar.XXXXXX")"
cat > "$plist_temporary" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$BAR_LABEL</string>
  <key>ProgramArguments</key><array><string>$BAR_BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
PLIST
plutil -lint "$plist_temporary" >/dev/null
chmod 600 "$plist_temporary"
mv -f "$plist_temporary" "$BAR_PLIST"
plist_temporary=""

log "Starting Hush"
open -a AeroSpace
aerospace_ready=false
for _ in {1..20}; do
    if aerospace list-workspaces --all >/dev/null 2>&1; then
        aerospace_ready=true
        break
    fi
    sleep 0.25
done
$aerospace_ready || die "AeroSpace did not become ready"
aerospace reload-config

launchctl bootout "gui/$UID_N/$BAR_LABEL" 2>/dev/null || true
bar_started=false
for _ in {1..10}; do
    if launchctl bootstrap "gui/$UID_N" "$BAR_PLIST" 2>/dev/null; then
        bar_started=true
        break
    fi
    sleep 0.25
done
$bar_started || die "The Hush bar LaunchAgent could not be started"
launchctl kickstart -k "gui/$UID_N/$BAR_LABEL"

# Clear persistent overrides left by Hush's first installer once. The current
# design only stops these optional helpers for this login session.
if grep -q '^menu-bar ' "$MANIFEST" && ! have cleared-legacy-karabiner-overrides; then
    launchctl enable "gui/$UID_N/org.pqrs.service.agent.Karabiner-Menu" 2>/dev/null || true
    launchctl enable "gui/$UID_N/org.pqrs.service.agent.Karabiner-NotificationWindow" \
        2>/dev/null || true
    mark cleared-legacy-karabiner-overrides
fi
launchctl kickstart -k "gui/$UID_N/org.pqrs.service.agent.karabiner_console_user_server" \
    2>/dev/null || true
for agent in Karabiner-Menu Karabiner-NotificationWindow; do
    launchctl bootout "gui/$UID_N/org.pqrs.service.agent.$agent" 2>/dev/null || true
done

open -g -a Tinycast
killall cfprefsd 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

if ! launchctl list 2>/dev/null | grep -q org.pqrs.service.agent.karabiner_console_user_server; then
    open -a Karabiner-Elements
fi

cat <<'EOF'

Hush installed. One-time permissions:
  1. AeroSpace: Privacy & Security -> Accessibility
  2. Karabiner-Elements: approve its driver and Input Monitoring

Ghostty and Tinycast were reused when already present; their Hush settings are repaired on every run.
Uninstall: ./uninstall.sh
EOF
