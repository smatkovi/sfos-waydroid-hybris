# Waydroid on Sailfish OS hybris ports

Install and configure Waydroid from [sailfishos:chum](https://github.com/sailfishos-chum)
on Sailfish OS devices that run on libhybris (community ports such as the
Verdandi Xperia 10 IV port), optionally with hardware rendering on the
device's Adreno GPU.

Tested on: Xperia 10 IV (XQ-CC54, `murray`, Adreno 619, Android 15 vendor),
Sailfish OS 5.1.0.11, waydroid 1.4.3, LineageOS 20 VANILLA system image.

## Usage

On the phone (Developer mode on, internet connection):

```sh
curl -fsSLO https://raw.githubusercontent.com/smatkovi/sfos-waydroid-hybris/main/setup.sh
devel-su sh setup.sh          # software rendering (safe default)
devel-su sh setup.sh --gpu    # experimental: Adreno GPU
```

(`sudo sh setup.sh` works too if sudo is set up.) Then start Android with the
**Waydroid** icon (waydroid-runner).

| Option | |
| --- | --- |
| `--gpu` | switch to the HALIUM vendor image and the host's Adreno driver (about 40 MB download) |
| `--no-gpu` | switch back to the MAINLINE vendor image, Mesa llvmpipe (about 140 MB) |
| `--no-init` | skip `waydroid init` (the 1 GB Android image download) |
| `--uninstall` | remove the fixup hook (packages stay installed) |

## What it does

1. Installs `waydroid waydroid-runner waydroid-settings waydroid-gbinder-config-hybris`
   with `zypper`. The Chum GUI reports "missing python dependencies" for Waydroid
   (and Pure Maps); the packages are in the Jolla repository and `zypper`
   resolves them fine.
2. Installs `/usr/local/sbin/waydroid-hybris-fixup` and runs it as
   `ExecStartPre` of `waydroid-container.service`, so the fixes below are
   re-applied after every waydroid package update:

| Problem | Fix |
| --- | --- |
| In MAINLINE mode Waydroid uses `/dev/binder`, which on hybris belongs to the host's Android HAL container. The container dies right after start. | Creates own binderfs devices `puddlejumper`, `vndpuddlejumper`, `hwpuddlejumper` (the names `waydroid-gbinder-config-hybris` expects) and writes them into `waydroid.cfg` and the LXC config. |
| `waydroid-net.sh` aborts: `iptables: No chain/target/match by that name` (kernel without the `CHECKSUM` target). | Makes that one rule non-fatal. |
| MAINLINE: Waydroid bind-mounts the host's Adreno EGL blobs over its own Mesa drivers, but still selects `gralloc=gbm`, `egl=mesa`. The composer aborts: `couldn't find an OpenGL ES implementation`. | Adds a `mount_host_egl` switch to `images.py` (`False` for MAINLINE, `True` for GPU mode). |
| GPU mode: Waydroid exposes the host's `/vendor` as `/vendor_extra`. An Android 15 vendor has no VNDK and ships its own `libhidlbase`, `libutils`, `libbase`, ... which shadow the container's VNDK v33 copies: Waydroid's own HALs crash (`cannot locate symbol`, `getBnConstructorMap returned null`). | `/vendor_extra` becomes a directory of symlinks to every host library except those the container provides itself (`container-core-libs.txt`); the host `/vendor` is mounted below `lib*/.host` so the Android linker's permitted paths still match. Rebuilt at every container start. |
| GPU mode: the host's Qualcomm mapper libraries need `std::__libcpp_verbose_abort` from a newer libc++ than Android 13 has, so `eglSubDriverAndroid.so` fails to load and SurfaceFlinger aborts with `EGL_BAD_DISPLAY`. | The host's `libc++.so` is allowed through `/vendor_extra`. |

### How GPU mode works

The HALIUM vendor image makes Waydroid pass graphics HALs through to the host:
the host's hwbinder appears in the container as `/dev/host_hwbinder`, buffers
come from the host's `vendor.qti.hardware.display.allocator-service`
(`IAllocator@4.0`), the container loads the host's
`mapper@4.0-impl-qti-display` and Adreno EGL/GLES libraries, and the Waydroid
hwcomposer hands the buffers to lipstick over the hybris `android_wlegl`
protocol (`ro.hardware.gralloc=android`, `ro.hardware.egl=adreno`).

## Limitations

- GPU mode is experimental and only tested on the Xperia 10 IV. It depends on
  the host vendor's libraries being loadable in an Android 13 process.
- `container-core-libs.txt` matches the LineageOS 20 Waydroid image (VNDK
  v28-v30, v33). A system image based on another Android version needs a new
  list.
- The fixup only touches what it recognises and prints a warning if upstream
  code changed.
