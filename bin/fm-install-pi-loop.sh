#!/usr/bin/env bash
# fm-install-pi-loop.sh - deploy the tracked loop-detector extension to the
# user-global extensions directory so pi loads it on crewmate sessions.
#
# Usage:
#   fm-install-pi-loop.sh
#
# Copies pi-extensions/firstmate-pi-loop.ts to ~/.pi/agent/extensions/firstmate-pi-loop.ts,
# creating the parent directory if it does not exist. Runs from the firstmate
# repo root; requires no arguments.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${HOME}/.pi/agent/extensions"
DEST_FILE="${DEST_DIR}/firstmate-pi-loop.ts"

mkdir -p "$DEST_DIR"
cp "$ROOT/pi-extensions/firstmate-pi-loop.ts" "$DEST_FILE"
printf 'fm-install-pi-loop.sh: installed %s\n' "$DEST_FILE"