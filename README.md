# Waydroid on Sailfish OS hybris ports

Install and configure Waydroid from [sailfishos:chum](https://github.com/sailfishos-chum)
on Sailfish OS devices that run on libhybris (community ports such as the
Verdandi Xperia 10 IV port).

Tested on: Xperia 10 IV (XQ-CC54, `murray`), Sailfish OS 5.1.0.11, waydroid 1.4.3,
LineageOS 20 VANILLA + MAINLINE vendor image.

## Usage

On the phone (Developer mode on, internet connection):

```sh
curl -fsSLO https://raw.githubusercontent.com/smatkovi/sfos-waydroid-hybris/main/setup.sh
devel-su sh setup.sh        # or: sudo sh setup.sh
```

Then start Android with the **Waydroid** icon (waydroid-runner). The first boot
takes about a minute. `setup.sh` downloads about 1 GB of Android images; pass
`--no-init` to skip that and run `waydroid init` yourself.

`sh setup.sh --uninstall` removes the fixup hook again (packages stay installed).

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
| Waydroid bind-mounts the host's Adreno EGL blobs over its own Mesa drivers, but still selects `gralloc=gbm`, `egl=mesa`. The composer aborts: `couldn't find an OpenGL ES implementation`. | Adds a `mount_host_egl` switch to `images.py` and sets `mount_host_egl = False`. |

## Limitations

- Graphics are software rendered (Mesa llvmpipe). The Adreno GPU sits behind
  `kgsl`, which Mesa's GL driver cannot use, and the host's Qualcomm gralloc
  lives in the host's Android HAL container, out of reach for Waydroid.
- Not tested on other devices. The fixup only touches what it recognises and
  prints a warning if upstream code changed.
