#!/usr/bin/env bash
# Install the "orbital" SDDM theme and make it the login screen.
#   sudo ~/.local/share/sddm-themes/orbital/install.sh
# Run it again after changing Orbital.qml / the shaders / the wallpaper to update the login,
# so the login screen always matches the orbital-lock screen (SUPER+L).
# Undo: sudo rm /etc/sddm.conf.d/orbital-theme.conf   (SDDM goes back to its default)
set -e
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
SRC="$(dirname "$(realpath "$0")")"
DST=/usr/share/sddm/themes/orbital

# make sure every file is there before touching the login screen
for f in Main.qml metadata.desktop theme.conf Orbital.qml Outfit-Black.ttf LICENSE-qylock background.jpg \
         shaders/blackhole.frag.qsb; do
    [[ -r $SRC/$f ]] || { echo "missing $SRC/$f"; exit 1; }
done

rm -rf "$DST"
mkdir -p "$DST"
# -L: the theme folder links to ~/.config/quickshell/lock; SDDM needs real copies
cp -L "$SRC"/{Main.qml,metadata.desktop,theme.conf,Orbital.qml,Outfit-Black.ttf,LICENSE-qylock,background.jpg} "$DST"/
# the black hole at the centre of the dial (and the unlock swallow) is a shader
cp -rL "$SRC/shaders" "$DST"/
chmod -R a+rX "$DST"

mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/orbital-theme.conf <<'CONF'
[Theme]
Current=orbital
CursorTheme=Bibata-Modern-Classic
CursorSize=24
CONF

echo "orbital login installed (Orbital.qml from $(date -r "$SRC/Orbital.qml" '+%b %d %H:%M'), shaders included)."
echo "Preview without logging out:  sddm-greeter-qt6 --test-mode --theme $DST"
echo "Undo: sudo rm /etc/sddm.conf.d/orbital-theme.conf"
