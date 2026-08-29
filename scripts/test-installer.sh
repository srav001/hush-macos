#!/usr/bin/env bash
# Exercise recovery and idempotency against isolated homes with system changes mocked.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/hush-installer-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/brew" <<'MOCK'
#!/usr/bin/env bash
set -e
has_cask() { [ -f "$MOCK_STATE/casks" ] && grep -qxF "$1" "$MOCK_STATE/casks"; }
add_cask() { has_cask "$1" || printf '%s\n' "$1" >> "$MOCK_STATE/casks"; }
remove_cask() { grep -vxF "$1" "$MOCK_STATE/casks" > "$MOCK_STATE/casks.next" || true; mv "$MOCK_STATE/casks.next" "$MOCK_STATE/casks"; }
make_app() {
    mkdir -p "$HUSH_APPLICATIONS_DIR/$1.app/Contents/MacOS"
    plutil -create xml1 "$HUSH_APPLICATIONS_DIR/$1.app/Contents/Info.plist"
    if [ "$1" = Ghostty ]; then bundle_id=com.mitchellh.ghostty; else bundle_id=com.tinycast.app; fi
    plutil -insert CFBundleIdentifier -string "$bundle_id" \
        "$HUSH_APPLICATIONS_DIR/$1.app/Contents/Info.plist"
    if [ "$1" = Ghostty ]; then
        printf '#!/usr/bin/env bash\nexit 0\n' > "$HUSH_APPLICATIONS_DIR/Ghostty.app/Contents/MacOS/ghostty"
        chmod +x "$HUSH_APPLICATIONS_DIR/Ghostty.app/Contents/MacOS/ghostty"
    fi
}

case "${1:-}" in
  list)
    [ "${2:-}" = --cask ] && { [ ! -f "$MOCK_STATE/casks" ] || cat "$MOCK_STATE/casks"; exit 0; } ;;
  tap)
    [ "$#" -eq 1 ] && { [ ! -f "$MOCK_STATE/taps" ] || cat "$MOCK_STATE/taps"; exit 0; } ;;
  trust)
    if [ "${2:-}" = --json=v1 ]; then printf '{"taps":[]}\n'; else printf 'trust %s\n' "$*" >> "$MOCK_STATE/actions"; fi
    exit 0 ;;
  bundle)
    if [ "${2:-}" = list ]; then
        printf 'aerospace\nfont-roboto-mono-nerd-font\nghostty\nkarabiner-elements\ntinycast\n'
        exit 0
    fi
    printf 'bundle-skip %s\n' "${HOMEBREW_BUNDLE_CASK_SKIP:-}" >> "$MOCK_STATE/actions"
    printf 'nikitabobko/tap\n' > "$MOCK_STATE/taps"
    ghostty_existed=false; tinycast_existed=false
    has_cask ghostty && ghostty_existed=true
    has_cask tinycast && tinycast_existed=true
    add_cask aerospace
    if [ "${FAIL_BUNDLE:-0}" = 1 ]; then exit 1; fi
    for cask in font-roboto-mono-nerd-font ghostty karabiner-elements tinycast; do
        case " ${HOMEBREW_BUNDLE_CASK_SKIP:-} " in *" $cask "*) continue ;; esac
        add_cask "$cask"
    done
    $ghostty_existed || { has_cask ghostty && make_app Ghostty; }
    $tinycast_existed || { has_cask tinycast && make_app Tinycast; }
    exit 0 ;;
  reinstall)
    printf 'reinstall %s\n' "$3" >> "$MOCK_STATE/actions"
    add_cask "$3"
    [ "$3" = ghostty ] && make_app Ghostty
    [ "$3" = tinycast ] && make_app Tinycast
    exit 0 ;;
  uninstall)
    cask="$3"
    [ "${FAIL_UNINSTALL:-}" != "$cask" ] || exit 1
    remove_cask "$cask"
    [ "$cask" != ghostty ] || rm -rf "$HUSH_APPLICATIONS_DIR/Ghostty.app"
    [ "$cask" != tinycast ] || rm -rf "$HUSH_APPLICATIONS_DIR/Tinycast.app"
    exit 0 ;;
  untap)
    [ "${FAIL_UNTAP:-0}" != 1 ] || exit 1
    : > "$MOCK_STATE/taps"
    exit 0 ;;
  untrust) exit 0 ;;
esac
printf 'unexpected brew call: %s\n' "$*" >&2
exit 1
MOCK

cat > "$MOCK_BIN/defaults" <<'MOCK'
#!/usr/bin/env bash
set -e
domain_file() { printf '%s/default-%s-%s' "$MOCK_STATE" "${1//\//_}" "${2//\//_}"; }
case "${1:-}" in
  read)
    file="$(domain_file "$2" "$3")"
    [ -f "$file" ] || exit 1
    cat "$file" ;;
  write)
    file="$(domain_file "$2" "$3")"
    value="$5"
    [ "$4" != -bool ] || { [ "$value" = true ] || [ "$value" = 1 ] && value=1 || value=0; }
    printf '%s\n' "$value" > "$file" ;;
  delete) rm -f "$(domain_file "$2" "$3")" ;;
  export)
    [ -f "$MOCK_STATE/spotlight.plist" ] || exit 1
    cp "$MOCK_STATE/spotlight.plist" "$3" ;;
  import) cp "$3" "$MOCK_STATE/spotlight.plist" ;;
  *) exit 1 ;;
esac
MOCK

cat > "$MOCK_BIN/system-mock" <<'MOCK'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$MOCK_STATE/actions"
if [ "$name" = launchctl ] && [ "${1:-}" = bootstrap ] &&
    [ "${FAIL_BOOTSTRAP_ONCE:-0}" = 1 ] && [ ! -f "$MOCK_STATE/bootstrap-failed" ]; then
    touch "$MOCK_STATE/bootstrap-failed"
    exit 5
fi
exit 0
MOCK

cat > "$MOCK_BIN/aerospace" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

chmod +x "$MOCK_BIN"/*
for name in launchctl killall open osascript; do ln -s system-mock "$MOCK_BIN/$name"; done

new_home() {
    local name="$1"
    export HOME="$TEST_DIR/$name/home"
    export MOCK_STATE="$TEST_DIR/$name/state"
    export HUSH_APPLICATIONS_DIR="$TEST_DIR/$name/Applications"
    mkdir -p "$HOME" "$MOCK_STATE" "$HUSH_APPLICATIONS_DIR"
    : > "$MOCK_STATE/actions"
    plutil -create xml1 "$MOCK_STATE/spotlight.plist"
    plutil -insert AppleSymbolicHotKeys -dictionary "$MOCK_STATE/spotlight.plist"
    plutil -insert AppleSymbolicHotKeys.64 -json \
        '{"enabled":true,"value":{"type":"standard","parameters":[32,49,1048576]}}' \
        "$MOCK_STATE/spotlight.plist"
}

export PATH="$MOCK_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Existing external apps are reused, settings converge, and the second run
# keeps the original backups—including a symlink.
new_home roundtrip
export FAIL_BOOTSTRAP_ONCE=1
mkdir -p "$HOME/.config/aerospace" "$HOME/.config/karabiner" \
    "$HOME/Library/Application Support/com.mitchellh.ghostty" "$HOME/.local/state/hush"
printf 'old managed aerospace\n' > "$HOME/.config/aerospace/aerospace.toml"
printf '{"old":"managed karabiner"}\n' > "$HOME/.config/karabiner/karabiner.json"
printf 'previous aerospace\n' > "$HOME/.local/state/hush/aerospace.toml.before"
printf '{"previous":"karabiner"}\n' > "$HOME/.local/state/hush/karabiner.json.before"
cat > "$HOME/.local/state/hush/manifest" <<'LEGACY'
had-file aerospace.toml
recorded-file aerospace.toml
had-file karabiner.json
recorded-file karabiner.json
menu-bar ABSENT
menu-bar-fullscreen 1
LEGACY
printf 'previous ghostty target\n' > "$HOME/ghostty-original"
ln -s "$HOME/ghostty-original" "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
mkdir -p "$HUSH_APPLICATIONS_DIR/Ghostty.app/Contents/MacOS" \
    "$HUSH_APPLICATIONS_DIR/Tinycast.app/Contents"
plutil -create xml1 "$HUSH_APPLICATIONS_DIR/Ghostty.app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.mitchellh.ghostty \
    "$HUSH_APPLICATIONS_DIR/Ghostty.app/Contents/Info.plist"
plutil -create xml1 "$HUSH_APPLICATIONS_DIR/Tinycast.app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.tinycast.app \
    "$HUSH_APPLICATIONS_DIR/Tinycast.app/Contents/Info.plist"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HUSH_APPLICATIONS_DIR/Ghostty.app/Contents/MacOS/ghostty"
chmod +x "$HUSH_APPLICATIONS_DIR/Ghostty.app/Contents/MacOS/ghostty"
printf '1\n' > "$MOCK_STATE/default-com.tinycast.app-showInMenuBar"
printf 'old\n' > "$MOCK_STATE/default-com.tinycast.app-hotkey.togglePalette"

"$REPO_DIR/install.sh" >/dev/null
"$REPO_DIR/install.sh" >/dev/null
unset FAIL_BOOTSTRAP_ONCE
test -f "$MOCK_STATE/bootstrap-failed"
grep -q '^bundle-skip ghostty tinycast$' "$MOCK_STATE/actions"
test ! -L "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
grep -qxF '0' "$MOCK_STATE/default-com.tinycast.app-showInMenuBar"
grep -qxF 'installed-cask aerospace' "$HOME/.local/state/hush/manifest"
! grep -qxF 'installed-cask ghostty' "$HOME/.local/state/hush/manifest"
"$REPO_DIR/uninstall.sh" >/dev/null
test -L "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
[ "$(readlink "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty")" = "$HOME/ghostty-original" ]
grep -qxF 'previous aerospace' "$HOME/.config/aerospace/aerospace.toml"
grep -qxF '{"previous":"karabiner"}' "$HOME/.config/karabiner/karabiner.json"
grep -qxF '1' "$MOCK_STATE/default-com.tinycast.app-showInMenuBar"
grep -qxF 'old' "$MOCK_STATE/default-com.tinycast.app-hotkey.togglePalette"
! plutil -type AppleSymbolicHotKeys.65 "$MOCK_STATE/spotlight.plist" >/dev/null 2>&1
test -d "$HUSH_APPLICATIONS_DIR/Ghostty.app"
test -d "$HUSH_APPLICATIONS_DIR/Tinycast.app"
test ! -e "$HOME/.local/state/hush"

# A partial Homebrew failure leaves ownership and recovery state for a safe rerun.
new_home partial
export FAIL_BUNDLE=1
if "$REPO_DIR/install.sh" >/dev/null 2>&1; then
    printf 'Installer ignored a partial Homebrew failure.\n' >&2
    exit 1
fi
unset FAIL_BUNDLE
test -f "$HOME/.local/state/hush/manifest"
grep -qxF 'installed-cask tinycast' "$HOME/.local/state/hush/manifest"

# Homebrew receipts with accidentally removed app bundles are repaired.
new_home repair
printf 'aerospace\nfont-roboto-mono-nerd-font\nghostty\nkarabiner-elements\ntinycast\n' > "$MOCK_STATE/casks"
"$REPO_DIR/install.sh" >/dev/null
grep -qxF 'reinstall ghostty' "$MOCK_STATE/actions"
grep -qxF 'reinstall tinycast' "$MOCK_STATE/actions"
test -x "$HUSH_APPLICATIONS_DIR/Ghostty.app/Contents/MacOS/ghostty"
test -d "$HUSH_APPLICATIONS_DIR/Tinycast.app"

# Missing recovery data makes uninstall fail without deleting the remaining state.
new_home recovery
mkdir -p "$HOME/.config/aerospace"
printf 'must survive\n' > "$HOME/.config/aerospace/aerospace.toml"
"$REPO_DIR/install.sh" >/dev/null
rm -f "$HOME/.local/state/hush/aerospace.toml.before"
if "$REPO_DIR/uninstall.sh" >/dev/null 2>&1; then
    printf 'Uninstall ignored a missing backup.\n' >&2
    exit 1
fi
test -f "$HOME/.local/state/hush/manifest"

# A fresh install never replaces an unowned runtime binary.
new_home ownership
mkdir -p "$HOME/.local/bin"
touch "$HOME/.local/bin/hush-bar"
if "$REPO_DIR/install.sh" >/dev/null 2>&1; then
    printf 'Installer overwrote an unowned runtime file.\n' >&2
    exit 1
fi

printf 'PASS: app reuse, idempotency, symlinks, partial failure and recovery\n'
