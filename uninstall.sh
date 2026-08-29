#!/usr/bin/env bash
# Remove only changes made by Hush; retain recovery state after any failure.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

[ -f "$MANIFEST" ] || {
    printf 'No Hush installation manifest found. Nothing changed.\n'
    exit 0
}

failures=0
failed() { printf '\033[1;31m==>\033[0m %s\n' "$1" >&2; failures=1; }

log "Stopping Hush services"
launchctl bootout "gui/$UID_N/$BAR_LABEL" 2>/dev/null || true
rm -f "$BAR_PLIST" "$BAR_BIN" "/tmp/hush-bar-ws-$UID_N" ||
    failed "Could not remove the Hush bar runtime"

tinycast_owned=false
have "installed-cask tinycast" && tinycast_owned=true
if have "recorded-default tinycast-menu"; then
    osascript -e 'quit app "Tinycast"' 2>/dev/null || true
fi

log "Restoring previous configurations"
while IFS='|' read -r name _ destination _; do
    restore_file "$destination" "$name" || failed "Could not restore $destination"
done < <(config_rows)
rmdir "$HOME/.config/aerospace" "$HOME/.config/karabiner" 2>/dev/null || true

restore_default NSGlobalDomain _HIHideMenuBar bool menu-bar ||
    failed "Could not restore the desktop menu bar setting"
restore_default NSGlobalDomain AppleMenuBarVisibleInFullscreen bool menu-bar-fullscreen ||
    failed "Could not restore the fullscreen menu bar setting"
restore_default com.tinycast.app showInMenuBar bool tinycast-menu ||
    failed "Could not restore Tinycast's menu setting"
restore_default com.tinycast.app compactMode bool tinycast-compact ||
    failed "Could not restore Tinycast's compact setting"
restore_default com.tinycast.app popToRootTimeout int tinycast-timeout ||
    failed "Could not restore Tinycast's timeout setting"
restore_default com.tinycast.app hotkey.togglePalette string tinycast-hotkey ||
    failed "Could not restore Tinycast's hotkey"
restore_spotlight_shortcut 64 || failed "Could not restore the Spotlight shortcut"
restore_spotlight_shortcut 65 || failed "Could not restore the Finder shortcut"

killall cfprefsd 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

if have "installed-cask aerospace"; then
    osascript -e 'quit app "AeroSpace"' 2>/dev/null || true
elif command -v aerospace >/dev/null 2>&1; then
    aerospace reload-config 2>/dev/null || failed "Could not reload AeroSpace"
fi

if grep -q '^installed-cask ' "$MANIFEST"; then
    log "Removing applications added by Hush"
    while IFS= read -r cask; do
        if [ -n "$cask" ] && brew_has_cask "$cask"; then
            brew uninstall --cask "$cask" || failed "Could not uninstall $cask"
        fi
    done < <(sed -n 's/^installed-cask //p' "$MANIFEST")
fi

if have "installed-tap nikitabobko/tap" && brew tap 2>/dev/null | grep -qxF nikitabobko/tap; then
    brew untap nikitabobko/tap || failed "Could not remove nikitabobko/tap"
fi
if have "trusted-tap nikitabobko/tap"; then
    brew untrust --tap nikitabobko/tap || failed "Could not remove the Homebrew trust entry"
fi

if ! $tinycast_owned && app_bundle_path Tinycast com.tinycast.app >/dev/null; then
    open -g -a Tinycast
fi

if [ "$failures" -ne 0 ]; then
    printf '\nUninstall incomplete. Recovery state remains at %s; run uninstall.sh again.\n' \
        "$STATE_DIR" >&2
    exit 1
fi

rm -rf "$STATE_DIR"
printf '\nHush uninstalled and the previous settings were restored.\n'
