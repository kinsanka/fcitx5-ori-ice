#!/usr/bin/env bash
# Fedora-only integration: real niri parsing and real Rime compilation, isolated HOME.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=install.sh
source ./install.sh
SANDBOX=$(mktemp -d /tmp/ori-ice-smoke.XXXXXXXX)
trap 'rm -rf -- "$SANDBOX"' EXIT
CONFIG_ROOT=$SANDBOX/config
DATA_ROOT=$SANDBOX/data
STATE_ROOT=$SANDBOX/state
NIRI_CONFIG=$CONFIG_ROOT/niri/config.kdl
export CONFIG_ROOT DATA_ROOT STATE_ROOT NIRI_CONFIG
WORK=$SANDBOX/work
mkdir -p "$WORK/ice" "$WORK/ori" "$CONFIG_ROOT/niri" "$SANDBOX/backup"
printf 'environment { TEST "keep"; }\n' >"$NIRI_CONFIG"
cp "$NIRI_CONFIG" "$SANDBOX/original.kdl"
download "https://codeload.github.com/iDvel/rime-ice/tar.gz/$ICE_REV" "$WORK/ice.tar.gz" "$ICE_SHA"
download "https://codeload.github.com/Reverier-Xu/Ori-fcitx5/tar.gz/$ORI_REV" "$WORK/ori.tar.gz" "$ORI_SHA"
tar -xzf "$WORK/ice.tar.gz" -C "$WORK/ice" --strip-components=1 --no-same-owner
tar -xzf "$WORK/ori.tar.gz" -C "$WORK/ori" --strip-components=1 --no-same-owner
configure snapshot "$SANDBOX/backup"
for schema in rime_ice double_pinyin_flypy; do
    configure apply "$WORK" dark "$schema"
    niri validate -c "$NIRI_CONFIG"
    rime_deployer --build "$CONFIG_ROOT/fcitx5/rime" /usr/share/rime-data \
        "$CONFIG_ROOT/fcitx5/rime/build" >"$SANDBOX/deploy.log" 2>&1 \
        || { cat "$SANDBOX/deploy.log"; exit 1; }
    test -s "$CONFIG_ROOT/fcitx5/rime/build/$schema.schema.yaml"
    test -s "$CONFIG_ROOT/fcitx5/rime/build/rime_ice.table.bin"
    # Compilation can succeed even when a plugin is unavailable: check Lua loading too.
    if rg -i 'error.*(lua|component)|unknown component|failed to load.*lua' "$SANDBOX/deploy.log"; then
        cat "$SANDBOX/deploy.log"
        exit 1
    fi
done
configure restore "$SANDBOX/backup"
cmp "$NIRI_CONFIG" "$SANDBOX/original.kdl"
test ! -e "$CONFIG_ROOT/fcitx5/rime"
niri validate -c "$NIRI_CONFIG"
printf '\nFedora smoke test passed: niri + full pinyin + flypy + restore.\n'
