#!/usr/bin/env bash
# Screenshot helper: saves to ~/Pictures/screenshots/ and copies to clipboard.
# usage: screenshot.sh [region|full] [edit]

MODE="${1:-region}"
EDIT="${2:-0}"

DIR="$HOME/Pictures/screenshots"
mkdir -p "$DIR"
FILE="$DIR/$(date +%Y-%m-%d_%H-%M-%S).png"

case "$MODE" in
    full)
        grim "$FILE"
        ;;
    *)
        grim -g "$(slurp)" "$FILE"
        ;;
esac

if [ -f "$FILE" ]; then
    wl-copy < "$FILE"
    echo "$FILE"
fi

if [ "$EDIT" = "1" ] && [ -f "$FILE" ]; then
    swappy -f "$FILE"
fi
