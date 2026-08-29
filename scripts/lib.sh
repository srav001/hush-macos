#!/usr/bin/env bash

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$HOME/.local/state/hush"
MANIFEST="$STATE_DIR/manifest"
BIN_DIR="$HOME/.local/bin"
AGENT_DIR="$HOME/Library/LaunchAgents"
BAR_LABEL="com.srav001.hush.bar"
BAR_BIN="$BIN_DIR/hush-bar"
BAR_PLIST="$AGENT_DIR/$BAR_LABEL.plist"
UID_N="$(id -u)"
APPLICATIONS_DIR="${HUSH_APPLICATIONS_DIR:-/Applications}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }
have() { [ -f "$MANIFEST" ] && grep -qxF "$1" "$MANIFEST"; }

mark() {
    have "$1" && return
    local temporary
    temporary="$(mktemp "$STATE_DIR/.manifest.XXXXXX")"
    [ ! -f "$MANIFEST" ] || cp -p "$MANIFEST" "$temporary"
    printf '%s\n' "$1" >> "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$MANIFEST"
}

replace_file() { # source, destination, mode
    local source="$1" destination="$2" mode="${3:-}" temporary
    mkdir -p "$(dirname "$destination")"
    temporary="$(mktemp "$(dirname "$destination")/.hush.XXXXXX")"
    if [ -L "$source" ]; then
        rm -f "$temporary"
        cp -P "$source" "$temporary"
    else
        cp -p "$source" "$temporary"
        [ -z "$mode" ] || chmod "$mode" "$temporary"
    fi
    mv -f "$temporary" "$destination"
}

record_file() { # destination, backup name
    local destination="$1" name="$2"
    have "recorded-file $name" && return
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        if [ -L "$destination" ]; then
            cp -P "$destination" "$STATE_DIR/$name.before"
        else
            cp -p "$destination" "$STATE_DIR/$name.before"
        fi
        mark "had-file $name"
    fi
    mark "recorded-file $name"
}

restore_file() { # destination, backup name
    local destination="$1" name="$2"
    have "recorded-file $name" || return 0
    if have "had-file $name"; then
        [ -e "$STATE_DIR/$name.before" ] || [ -L "$STATE_DIR/$name.before" ] || return 1
        replace_file "$STATE_DIR/$name.before" "$destination"
    else
        rm -f "$destination"
    fi
}

config_rows() {
    printf '%s\n' \
        "aerospace.toml|$REPO_DIR/config/aerospace/aerospace.toml|$HOME/.config/aerospace/aerospace.toml|600" \
        "karabiner.json|$REPO_DIR/config/karabiner/karabiner.json|$HOME/.config/karabiner/karabiner.json|600" \
        "ghostty|$REPO_DIR/config/ghostty/config|$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty|644"
}

record_default() { # domain, key, backup name
    local domain="$1" key="$2" name="$3"
    have "recorded-default $name" && return
    if defaults read "$domain" "$key" > "$STATE_DIR/$name.before" 2>/dev/null; then
        mark "had-default $name"
    fi
    mark "recorded-default $name"
}

default_equals() { # domain, key, type, desired
    local domain="$1" key="$2" type="$3" desired="$4" current
    current="$(defaults read "$domain" "$key" 2>/dev/null)" || return 1
    case "$type:$current:$desired" in
        bool:true:1|bool:false:0|bool:1:1|bool:0:0) return 0 ;;
    esac
    [ "$current" = "$desired" ]
}

write_default() { # domain, key, type, value
    defaults write "$1" "$2" "-$3" "$4"
}

restore_default() { # domain, key, type, backup name
    local domain="$1" key="$2" type="$3" name="$4" previous
    have "recorded-default $name" || return 0
    if have "had-default $name"; then
        [ -f "$STATE_DIR/$name.before" ] || return 1
        previous="$(<"$STATE_DIR/$name.before")"
        write_default "$domain" "$key" "$type" "$previous"
    else
        if defaults read "$domain" "$key" >/dev/null 2>&1; then
            defaults delete "$domain" "$key"
        fi
    fi
}

brew_has_cask() {
    brew list --cask 2>/dev/null | grep -qxF "$1"
}

app_bundle_path() { # app name, bundle id
    local name="$1" bundle_id="$2" candidate
    for candidate in "$APPLICATIONS_DIR/$name.app" "$HOME/Applications/$name.app"; do
        if [ -d "$candidate" ] &&
            [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                "$candidate/Contents/Info.plist" 2>/dev/null)" = "$bundle_id" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if [ -z "${HUSH_APPLICATIONS_DIR+x}" ] && command -v mdfind >/dev/null 2>&1; then
        candidate="$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" | head -1)"
        [ -d "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    fi
    return 1
}

record_spotlight_shortcut() { # id
    local id="$1" snapshot
    have "recorded-spotlight $id" && return
    snapshot="$(mktemp "$STATE_DIR/.spotlight.XXXXXX")"
    if defaults export com.apple.symbolichotkeys "$snapshot" 2>/dev/null &&
        plutil -extract "AppleSymbolicHotKeys.$id" json \
            -o "$STATE_DIR/spotlight-$id.before.json" "$snapshot" 2>/dev/null; then
        mark "had-spotlight $id"
    fi
    rm -f "$snapshot"
    mark "recorded-spotlight $id"
}

update_spotlight_shortcut() { # id, JSON or empty to remove
    local id="$1" value="${2:-}" snapshot
    snapshot="$(mktemp "$STATE_DIR/.spotlight.XXXXXX")"
    defaults export com.apple.symbolichotkeys "$snapshot" 2>/dev/null || plutil -create xml1 "$snapshot"
    plutil -type AppleSymbolicHotKeys "$snapshot" >/dev/null 2>&1 ||
        plutil -insert AppleSymbolicHotKeys -dictionary "$snapshot"
    if [ -n "$value" ]; then
        plutil -replace "AppleSymbolicHotKeys.$id" -json "$value" "$snapshot" 2>/dev/null ||
            plutil -insert "AppleSymbolicHotKeys.$id" -json "$value" "$snapshot"
    else
        if plutil -type "AppleSymbolicHotKeys.$id" "$snapshot" >/dev/null 2>&1; then
            plutil -remove "AppleSymbolicHotKeys.$id" "$snapshot"
        fi
    fi
    defaults import com.apple.symbolichotkeys "$snapshot"
    rm -f "$snapshot"
}

restore_spotlight_shortcut() { # id
    local id="$1"
    have "recorded-spotlight $id" || return 0
    if have "had-spotlight $id"; then
        [ -f "$STATE_DIR/spotlight-$id.before.json" ] || return 1
        update_spotlight_shortcut "$id" "$(<"$STATE_DIR/spotlight-$id.before.json")"
    else
        update_spotlight_shortcut "$id"
    fi
}
