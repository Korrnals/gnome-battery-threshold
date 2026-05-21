#!/usr/bin/env bash
# Battery Threshold — one-shot installer.
# Detects the host package manager, downloads the matching asset from the
# latest GitHub Release and installs it.
#
# Usage (run as your user — script will sudo internally):
#   curl -fsSL https://raw.githubusercontent.com/Korrnals/gnome-battery-threshold/main/scripts/install.sh | bash
#
# Environment overrides:
#   BT_REPO    override repo slug (default: Korrnals/gnome-battery-threshold)
#   BT_TAG     install a specific tag instead of the latest release
#   BT_FORMAT  force package format: rpm | deb
set -euo pipefail

REPO="${BT_REPO:-Korrnals/gnome-battery-threshold}"
API="https://api.github.com/repos/${REPO}"

c_info()  { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
c_err()   { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { c_err "Missing dependency: $1"; exit 1; }; }
need curl

# ── Detect package format ───────────────────────────────────────────────────
detect_format() {
    if [[ -n "${BT_FORMAT:-}" ]]; then
        echo "$BT_FORMAT"; return
    fi
    if   command -v dnf      >/dev/null 2>&1; then echo rpm
    elif command -v zypper   >/dev/null 2>&1; then echo rpm
    elif command -v rpm      >/dev/null 2>&1; then echo rpm
    elif command -v apt-get  >/dev/null 2>&1; then echo deb
    elif command -v dpkg     >/dev/null 2>&1; then echo deb
    else
        c_err "Unsupported package manager. Use the from-source install path."
        exit 1
    fi
}

# ── Pick installer command ──────────────────────────────────────────────────
install_cmd() {
    local fmt="$1" file="$2"
    case "$fmt" in
        rpm)
            if   command -v dnf    >/dev/null 2>&1; then sudo dnf install -y "$file"
            elif command -v zypper >/dev/null 2>&1; then sudo zypper --non-interactive install --allow-unsigned-rpm "$file"
            else                                          sudo rpm -i "$file"
            fi
            ;;
        deb)
            if   command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y "$file"
            else                                          sudo dpkg -i "$file" || sudo apt-get -f install -y
            fi
            ;;
        *) c_err "Unknown format: $fmt"; exit 1 ;;
    esac
}

# ── Resolve release ─────────────────────────────────────────────────────────
fmt=$(detect_format)
c_info "Detected package format: $fmt"

if [[ -n "${BT_TAG:-}" ]]; then
    release_url="${API}/releases/tags/${BT_TAG}"
else
    release_url="${API}/releases/latest"
fi

c_info "Querying GitHub Release..."
release_json=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$release_url")
tag=$(printf '%s' "$release_json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
[[ -n "$tag" ]] || { c_err "Could not parse tag_name from release JSON."; exit 1; }
c_info "Release: $tag"

# Pick asset URL matching format
asset_url=$(printf '%s' "$release_json" \
    | grep -oE '"browser_download_url": *"[^"]+"' \
    | sed -E 's/^"browser_download_url": *"([^"]+)"$/\1/' \
    | grep -E "\.${fmt}\$" \
    | head -n1)

[[ -n "$asset_url" ]] || { c_err "No .${fmt} asset found in release $tag."; exit 1; }
c_ok "Asset: $asset_url"

# ── Download & install ──────────────────────────────────────────────────────
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
file="${tmp}/$(basename "$asset_url")"

c_info "Downloading..."
curl -fL --progress-bar -o "$file" "$asset_url"

c_info "Installing $(basename "$file")..."
install_cmd "$fmt" "$file"
c_ok "Package installed."

# ── Finalise extension ──────────────────────────────────────────────────────
if command -v gnome-extensions >/dev/null 2>&1; then
    uuid="battery-threshold@korrnals.github.io"
    if gnome-extensions list 2>/dev/null | grep -qx "$uuid"; then
        c_info "Enabling GNOME extension..."
        gnome-extensions enable "$uuid" || true
        c_ok "Done. Log out and back in if the panel icon doesn't appear."
    else
        c_info "Extension not yet visible to GNOME Shell — log out and back in,"
        c_info "then run: gnome-extensions enable $uuid"
    fi
else
    c_info "gnome-extensions CLI not found — extension was installed but enable manually:"
    c_info "  gnome-extensions enable battery-threshold@korrnals.github.io"
fi

c_ok "All done. Open the panel battery icon to configure thresholds."
