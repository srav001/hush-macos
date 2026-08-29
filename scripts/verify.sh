#!/usr/bin/env bash
# Non-invasive verification: compiles into /tmp and changes no user settings.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_DIR="$(mktemp -d /tmp/hush-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT

cd "$REPO_DIR"

bash -n install.sh uninstall.sh scripts/lib.sh scripts/verify.sh scripts/test-installer.sh
jq empty config/karabiner/karabiner.json
[ "$(rg -c '^\[mode\..*\.binding\]$' config/aerospace/aerospace.toml)" -eq 2 ]
[ "$(rg -c '^cmd-ctrl-alt-[1-9] = ' config/aerospace/aerospace.toml)" -eq 9 ]

ghostty="/Applications/Ghostty.app/Contents/MacOS/ghostty"
[ ! -x "$ghostty" ] || "$ghostty" +validate-config \
    --config-file="$REPO_DIR/config/ghostty/config"

swiftc -O -o "$VERIFY_DIR/hush-bar" helper/bar.swift
codesign --force --sign - --identifier com.srav001.hush.bar \
    "$VERIFY_DIR/hush-bar" >/dev/null
codesign --verify --strict "$VERIFY_DIR/hush-bar"

if otool -L "$VERIFY_DIR/hush-bar" | grep -q DisplayServices; then
    printf 'The bar hard-links the private DisplayServices framework.\n' >&2
    exit 1
fi

if rg -n 'URLSession|CoreLocation|CoreBluetooth|CoreWLAN|IOBluetooth|ScreenCaptureKit' \
    helper/bar.swift; then
    printf 'Unexpected privacy-sensitive or network framework in active Swift code.\n' >&2
    exit 1
fi

if rg -n '\.zshrc|TrackpadFourFinger|aerospace-swipe' install.sh uninstall.sh scripts/lib.sh; then
    printf 'Installer unexpectedly touches an excluded user feature.\n' >&2
    exit 1
fi

expected_casks=$'aerospace\nfont-roboto-mono-nerd-font\nghostty\nkarabiner-elements\ntinycast'
actual_casks="$(brew bundle list --cask --file=Brewfile | sort)"
[ "$actual_casks" = "$expected_casks" ] || {
    printf 'Unexpected Brewfile casks:\n%s\n' "$actual_casks" >&2
    exit 1
}

git diff --check
printf 'PASS: syntax, settings, privacy boundary, compilation and signing\n'
