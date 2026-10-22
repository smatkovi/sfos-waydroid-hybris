#!/bin/sh
# Installs Waydroid from sailfishos:chum and configures it for Sailfish OS
# hybris ports. Run as root on the phone:
#   devel-su sh setup.sh            (or: sudo sh setup.sh)
# Options:
#   --no-init     do not download the Android images (waydroid init)
#   --uninstall   remove the fixup hook (packages stay installed)
set -e

REPO_RAW=https://raw.githubusercontent.com/smatkovi/sfos-waydroid-hybris/main
FIXUP=/usr/local/sbin/waydroid-hybris-fixup
DROPIN_DIR=/etc/systemd/system/waydroid-container.service.d
DROPIN=$DROPIN_DIR/10-hybris-fixup.conf
PACKAGES="waydroid waydroid-runner waydroid-settings waydroid-gbinder-config-hybris"

DO_INIT=1
for a in "$@"; do
    case "$a" in
        --no-init) DO_INIT=0 ;;
        --uninstall)
            rm -f "$DROPIN" "$FIXUP"
            rmdir "$DROPIN_DIR" 2>/dev/null || true
            systemctl daemon-reload
            echo "Fixup hook removed. Packages are still installed."
            exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = 0 ] || { echo "Run as root (devel-su or sudo)." >&2; exit 1; }

echo "== Checking kernel"
if [ ! -e /dev/binderfs/binder-control ]; then
    echo "No /dev/binderfs/binder-control - this setup needs a kernel with binderfs." >&2
    exit 1
fi

echo "== Checking chum repository"
if ! ssu lr 2>/dev/null | grep -q 'sailfishos-chum'; then
    echo "sailfishos:chum is not enabled. Install the Chum GUI or run:" >&2
    echo "  ssu ar sailfishos-chum https://repo.sailfishos.org/obs/sailfishos:/chum/\$(ssu re | sed -n 's/.*: //p' | cut -d. -f1,2)_\$(uname -m)/" >&2
    exit 1
fi

echo "== Installing packages: $PACKAGES"
# zypper directly: the Chum GUI/PackageKit wrongly reports missing python3
# dependencies for these packages, they are all in the Jolla repository.
zypper -n --gpg-auto-import-keys refresh >/dev/null || true
zypper -n install $PACKAGES

echo "== Installing fixup hook"
SRC_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)
mkdir -p "$(dirname "$FIXUP")"
if [ -f "$SRC_DIR/waydroid-hybris-fixup" ]; then
    cp "$SRC_DIR/waydroid-hybris-fixup" "$FIXUP"
else
    curl -fsSL "$REPO_RAW/waydroid-hybris-fixup" -o "$FIXUP"
fi
chmod 755 "$FIXUP"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<EOF
[Unit]
After=dev-binderfs.mount

[Service]
ExecStartPre=$FIXUP
EOF
systemctl daemon-reload

"$FIXUP"

if [ "$DO_INIT" = 1 ] && [ ! -f /var/lib/waydroid/waydroid.cfg ]; then
    echo "== Downloading Android images (waydroid init, about 1 GB)"
    systemctl stop waydroid-container 2>/dev/null || true
    waydroid init
fi

# In MAINLINE mode init still picks /dev/binder; correct cfg and LXC config.
"$FIXUP"

echo "== Starting container service"
systemctl enable waydroid-container >/dev/null 2>&1 || true
systemctl restart waydroid-container

echo
echo "Done. Start Android with the \"Waydroid\" icon (waydroid-runner)."
echo "Graphics are software rendered (Mesa llvmpipe)."
