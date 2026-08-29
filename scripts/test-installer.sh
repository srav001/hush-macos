#!/usr/bin/env bash
# Exercise install/uninstall against an isolated HOME with system mutations mocked.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/hush-installer-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

TEST_HOME="$TEST_DIR/home"
MOCK_BIN="$TEST_DIR/bin"
MOCK_STATE="$TEST_DIR/mock-state"
mkdir -p "$TEST_HOME/.config/aerospace" "$TEST_HOME/.config/karabiner" \
    "$TEST_HOME/.config/ghostty" \
    "$TEST_HOME/Library/Application Support/Tinycast" \
    "$MOCK_BIN" "$MOCK_STATE"

printf 'previous aerospace\n' > "$TEST_HOME/.config/aerospace/aerospace.toml"
printf '{"previous":"karabiner"}\n' > "$TEST_HOME/.config/karabiner/karabiner.json"
printf 'previous ghostty\n' > "$TEST_HOME/.config/ghostty/config"
printf 'previous shell\n' > "$TEST_HOME/.zshrc"
printf 'previous tinycast\n' > "$TEST_HOME/Library/Application Support/Tinycast/marker"

cat > "$MOCK_BIN/brew" <<'MOCK'
#!/usr/bin/env bash
set -e
case "${1:-} ${2:-}" in
  "list --cask") [ ! -f "$MOCK_STATE/casks" ] || cat "$MOCK_STATE/casks" ;;
  "tap ") [ ! -f "$MOCK_STATE/taps" ] || cat "$MOCK_STATE/taps" ;;
  "trust --json=v1") printf '{"taps":[],"formulae":[],"casks":[],"commands":[]}\n' ;;
  "trust --tap") printf 'brew %s\n' "$*" >> "$MOCK_STATE/actions" ;;
  "bundle --file="*)
    printf 'aerospace\nkarabiner-elements\n' > "$MOCK_STATE/casks"
    printf 'nikitabobko/tap\n' > "$MOCK_STATE/taps" ;;
  "bundle list")
    case "$*" in
      *--cask*) printf 'aerospace\nkarabiner-elements\n' ;;
      *--tap*) printf 'nikitabobko/tap\n' ;;
    esac ;;
  "uninstall --cask") printf 'brew %s\n' "$*" >> "$MOCK_STATE/actions" ;;
  "untap nikitabobko/tap"|"untrust --tap") printf 'brew %s\n' "$*" >> "$MOCK_STATE/actions" ;;
  *) printf 'unexpected brew call: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK

cat > "$MOCK_BIN/system-mock" <<'MOCK'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$MOCK_STATE/actions"
if [ "$name" = defaults ] && [ "${1:-}" = read ]; then exit 1; fi
if [ "$name" = launchctl ] && [ "${1:-}" = print-disabled ]; then printf '{}\n'; fi
exit 0
MOCK

chmod +x "$MOCK_BIN/brew" "$MOCK_BIN/system-mock"
for name in launchctl defaults killall open pkill osascript; do
    ln -s system-mock "$MOCK_BIN/$name"
done

export HOME="$TEST_HOME"
export MOCK_STATE
export PATH="$MOCK_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

"$REPO_DIR/install.sh" >/dev/null

test -x "$HOME/.local/bin/hush-bar"
cmp -s "$REPO_DIR/config/aerospace/aerospace.toml" "$HOME/.config/aerospace/aerospace.toml"
cmp -s "$REPO_DIR/config/karabiner/karabiner.json" "$HOME/.config/karabiner/karabiner.json"
plutil -lint "$HOME/Library/LaunchAgents/com.srav001.hush.bar.plist" >/dev/null
grep -qxF 'installed-cask aerospace' "$HOME/.local/state/hush/manifest"
grep -qxF 'installed-cask karabiner-elements' "$HOME/.local/state/hush/manifest"

"$REPO_DIR/uninstall.sh" >/dev/null

grep -qxF 'previous aerospace' "$HOME/.config/aerospace/aerospace.toml"
grep -qxF '{"previous":"karabiner"}' "$HOME/.config/karabiner/karabiner.json"
grep -qxF 'previous ghostty' "$HOME/.config/ghostty/config"
grep -qxF 'previous shell' "$HOME/.zshrc"
grep -qxF 'previous tinycast' "$HOME/Library/Application Support/Tinycast/marker"
test ! -e "$HOME/.local/bin/hush-bar"
test ! -e "$HOME/.local/state/hush"

mkdir -p "$HOME/.local/bin"
touch "$HOME/.local/bin/hush-bar"
if "$REPO_DIR/install.sh" >/dev/null 2>&1; then
    printf 'Installer overwrote an unowned runtime file.\n' >&2
    exit 1
fi

printf 'PASS: isolated install/uninstall round trip\n'
