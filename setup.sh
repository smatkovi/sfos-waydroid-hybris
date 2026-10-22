#!/bin/sh
# Installs Waydroid from sailfishos:chum and configures it for Sailfish OS
# hybris ports. Run as root on the phone:
#   devel-su sh setup.sh            (or: sudo sh setup.sh)
# Options:
#   (default)     hardware rendering with the host's Adreno driver
#                 (HALIUM vendor image, tested on Xperia 10 IV)
#   --no-gpu      software rendering instead (MAINLINE vendor image)
#   --no-init     do not download the Android images (waydroid init)
#   --uninstall   remove the fixup hook (packages stay installed)
set -e

REPO_RAW=https://raw.githubusercontent.com/smatkovi/sfos-waydroid-hybris/main
FIXUP=/usr/local/sbin/waydroid-hybris-fixup
DROPIN_DIR=/etc/systemd/system/waydroid-container.service.d
DROPIN=$DROPIN_DIR/10-hybris-fixup.conf
SHARE=/usr/local/share/waydroid-hybris
PACKAGES="waydroid waydroid-runner waydroid-settings waydroid-gbinder-config-hybris"

DO_INIT=1
GPU=HALIUM_13
for a in "$@"; do
    case "$a" in
        --no-init) DO_INIT=0 ;;
        --gpu) GPU=HALIUM_13 ;;
        --no-gpu) GPU=MAINLINE ;;
        --uninstall)
            rm -f "$DROPIN" "$FIXUP"
            rm -rf "$SHARE"
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
fetch() {  # fetch <repo file> <destination>
    if [ -f "$SRC_DIR/$1" ]; then cp "$SRC_DIR/$1" "$2"
    else curl -fsSL "$REPO_RAW/$1" -o "$2"; fi
}
mkdir -p "$(dirname "$FIXUP")" "$SHARE"
fetch waydroid-hybris-fixup "$FIXUP"
fetch container-core-libs.txt "$SHARE/container-core-libs.txt"
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

# Switch the vendor image: HALIUM_13 (host Adreno + Qualcomm gralloc through
# the host's hwbinder) or MAINLINE (Mesa llvmpipe). waydroid init cannot be
# told the vendor type on hybris (host getprop has no ro.vndk.version), so
# the image is fetched from the Waydroid OTA server directly.
switch_vendor() {
    cfg=/var/lib/waydroid/waydroid.cfg
    [ -f "$cfg" ] || { echo "Waydroid is not initialised yet." >&2; exit 1; }
    grep -q "^vendor_type = $1\$" "$cfg" && return
    echo "== Switching vendor image to $1"
    systemctl stop waydroid-container 2>/dev/null || true
    python3 - "$1" <<'EOF'
import hashlib, json, os, sys, urllib.request, zipfile
vtype = sys.argv[1]
ota = "https://ota.waydro.id/vendor/waydroid_arm64/%s.json" % vtype
entry = json.load(urllib.request.urlopen(ota))["response"][0]
images = "/var/lib/waydroid/images"
tmp = images + "/vendor.zip.part"
print("downloading", entry["filename"], "(%d MB)" % (entry["size"] // 2**20))
urllib.request.urlretrieve(entry["url"], tmp)
if hashlib.sha256(open(tmp, "rb").read()).hexdigest() != entry["id"]:
    os.remove(tmp)
    sys.exit("checksum mismatch")
with zipfile.ZipFile(tmp) as z:
    z.extract("vendor.img", images + "/.new")
os.replace(images + "/.new/vendor.img", images + "/vendor.img")
os.rmdir(images + "/.new")
os.remove(tmp)
cfg = "/var/lib/waydroid/waydroid.cfg"
lines = open(cfg).read().splitlines()
new = {"vendor_type": vtype, "vendor_ota": ota,
       "vendor_datetime": str(entry["datetime"]),
       "mount_host_egl": "False" if vtype == "MAINLINE" else "True"}
out = []
for l in lines:
    k = l.split(" = ")[0]
    out.append(k + " = " + new.pop(k) if k in new else l)
    if l == "[waydroid]":
        out += [k + " = " + v for k, v in list(new.items()) if not any(x.startswith(k + " = ") for x in lines)]
open(cfg, "w").write("\n".join(out) + "\n")
EOF
    # regenerates the LXC config and props for the new vendor type
    waydroid upgrade --offline >/dev/null 2>&1 || true
}
[ -f /var/lib/waydroid/waydroid.cfg ] && switch_vendor "$GPU"

# In MAINLINE mode init still picks /dev/binder; correct cfg and LXC config.
"$FIXUP"

echo "== Starting container service"
systemctl enable waydroid-container >/dev/null 2>&1 || true
systemctl restart waydroid-container

echo
echo "Done. Start Android with the \"Waydroid\" icon (waydroid-runner)."
if grep -q '^vendor_type = HALIUM' /var/lib/waydroid/waydroid.cfg 2>/dev/null; then
    echo "Graphics: host Adreno GPU (--no-gpu switches to software rendering)."
else
    echo "Graphics: software rendering (Mesa llvmpipe), run without --no-gpu for the Adreno GPU."
fi
