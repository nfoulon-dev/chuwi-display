# chuwi-fold

Everything needed to make a CHUWI MiniBook X behave like a convertible on
Fedora, in one command:

- **Panel**: the BIOS drives this 1200x1920 DSI panel at 50 Hz and it is mounted
  rotated 270 degrees. The Video BIOS Table is patched to drive it at 90 Hz and
  loaded early via `i915.vbt_firmware=vbt`, and the kernel is told the panel
  orientation, so Plymouth, GDM, GNOME and the VT consoles come up upright.
- **Fold / tablet mode**: fold the display back past 185 degrees -- fully folded
  *or* in tent mode -- and the internal keyboard and touchpad are suspended.
  Unfold, and they come back with the panel already back in landscape.
- **Hardware video decode**: Fedora does not ship Intel's iHD media driver (it
  lives in RPM Fusion because of codec patents), so this enables RPM Fusion,
  installs `intel-media-driver` and turns VA-API on in Firefox.

Both halves are installed together because neither is much use alone: the kernel
supplying `panel_orientation` is what makes mutter land in portrait when tablet
mode ends, and the sensor side only turns its own panel compensation off when
the kernel supplies that orientation. Install one without the other and the
desktop ends up rotated, or rotated twice.

Tested on a MiniBook X (Intel N150) running Fedora 44 with GNOME 50 on Wayland,
libinput 1.31.3, kernel 7.2.9. The installer is tested end to end in clean
`fedora:44` and `fedora:45` containers.

## Install

```
git clone https://github.com/nfoulon-dev/chuwi-fold.git
cd chuwi-fold
./install
```

`./install` elevates itself with sudo. It installs the build dependencies
(`meson`, `ninja-build`, `gcc`, `glib2-devel`, `libdrm-devel`, `polkit-devel`,
`systemd-devel`, `libgudev-devel`, `pkgconf-pkg-config`, `systemd`, `git` and the
SELinux tools), clones
[fstanis/chuwi-minibook](https://github.com/fstanis/chuwi-minibook), applies
[patches/](patches), builds the forked `iio-sensor-proxy`, then sets up the panel
and installs everything listed below. It needs network access, is safe to re-run,
and nothing it installs is owned by the `iio-sensor-proxy` package, so
`dnf upgrade` cannot break it.

**Reboot once** when it finishes: the panel half is staged for the next boot. The
fold feature works either way.

```
./install [--hz N] [--keep-grub-menu] [--no-panel-fixes]
```

| Option | Meaning |
| --- | --- |
| `--hz N` | refresh rate to patch into the VBT (default 90, try `60` if 90 shows artifacts) |
| `--keep-grub-menu` | leave the boot menu visible; GRUB cannot rotate its text, so it stays sideways |
| `--no-panel-fixes` | install only the fold half |
| `--no-vaapi` | do not set up hardware video decode |
| `--no-firefox` | do not write the Firefox VA-API preferences |

Environment overrides: `CHUWI_MINIBOOK=/path/to/checkout` to reuse an existing
clone, `IIO_BINARY=/path/to/iio-sensor-proxy` to skip the source and build,
`DESTDIR=/tmp/x` to install into a prefix and make no system changes.

## Why this is needed

The MiniBook X reports no tablet-mode switch at all:

- no `SW_TABLET_MODE` device exists, only the lid switch,
- ACPI `_SB.CONV` (`INT33D3`) is a stub with no `_CRS`, so nothing binds to it,
- the vendor's own slate detection (`_SB.ACMK.LTSM` -> EC `KBCD`) is never called
  by firmware; it is a hook for the Windows sensor driver, which decides from the
  accelerometer angle.

So the hinge angle has to be derived in software, and the panel orientation has
to come from the kernel rather than from firmware that never set it.

## How it works

1. **Hinge angle.** Two MXC6655 accelerometers sit behind one ACPI device
   (`MDA6655`); only one is visible through IIO. The forked `iio-sensor-proxy` in
   [patches/](patches) reads both over raw I2C, computes the hinge angle from the
   gravity vectors, and publishes `SW_TABLET_MODE` on a uinput device once the
   angle stays above 185 degrees for 250 ms (175 degrees to come back). libinput
   pairs that switch with the internal keyboard and touchpad and suspends them,
   which is also what raises the on-screen keyboard.
2. **Landscape after unfolding.** On leaving tablet mode mutter resets the
   built-in panel to the DRM panel-orientation default, which on this panel is
   portrait, so the desktop would stay rotated. The user daemon in
   [files/minibook-rotation-fix.py](files/minibook-rotation-fix.py) reapplies
   landscape whenever the switch is off and does nothing while it is on, so
   GNOME's own auto-rotation is untouched in tablet and tent mode.
3. **Panel.** [tools/panel_fixes.sh](tools/panel_fixes.sh) reads the running VBT
   from debugfs, patches its pixel clock with
   [tools/vbt_patch.py](tools/vbt_patch.py) (a self-contained port of
   `vbt_patch.c` from chuwi-minibook), bundles it into the initramfs, and adds
   `i915.vbt_firmware=vbt video=DSI-1:panel_orientation=right_side_up
   fbcon=rotate:1` to the kernel command line. It hides the boot menu, because
   GRUB cannot rotate its text, and it resets a manual rotation left in
   `monitors.xml` by a previous setup.

## What gets installed

| Path | What |
| --- | --- |
| `/lib/firmware/vbt` | the patched VBT, loaded via `i915.vbt_firmware=vbt` |
| `/etc/dracut.conf.d/minibook-vbt.conf` | bundles it into the initramfs |
| `/usr/local/libexec/iio-sensor-proxy` | the forked sensor proxy (not owned by the package) |
| `/etc/systemd/system/iio-sensor-proxy.service` | starts that binary |
| `/etc/systemd/system/iio-sensor-proxy.service.d/panel.conf` | disables the fork's panel compensation while the kernel supplies the orientation |
| `/etc/udev/rules.d/70-minibook-rotation-fix.rules` | gives the session user read access to the switch device |
| SELinux module `minibook_iio_sensor_proxy` | lets the confined service read both i2c accelerometers, DRM and uinput |
| `~/.local/bin/minibook-rotation-fix.py` | landscape daemon |
| `~/.config/systemd/user/minibook-rotation-fix.service` | starts it with the session |
| RPM Fusion release packages | repository holding the Intel media driver |
| `intel-media-driver`, `libva-utils` | hardware decode driver, and `vainfo` to check it |
| `<firefox profile>/user.js` | enables VA-API decode in Firefox |

The panel half also edits `/etc/default/grub`, the kernel command line (through
`grubby`) and `~/.config/monitors.xml`, keeping a copy of each in
`/root/minibook-fix-backups/<timestamp>/` first.

## Uninstall

```
./uninstall                     # fold half and panel fixes
./uninstall --keep-panel-fixes  # only the fold half
```

It removes the files above, drops the SELinux module, reverts the panel settings
and reinstalls the distribution's `iio-sensor-proxy`. A reboot puts the panel
back to stock; without one, folding is already inert. The video decode packages
are left in place, since they are useful on their own and harmless.

## Hardware video decode

Fedora ships no Intel iHD driver, so VA-API falls back to software decode unless
RPM Fusion is enabled and `intel-media-driver` is installed; the Firefox
preferences (`media.ffmpeg.vaapi.enabled`, `media.hardware-video-decoding.enabled`)
are written into each profile's `user.js`, which Firefox reapplies on every
launch. `intel-media-driver` is also what puts the driver at
`/usr/lib64/dri-nonfree/iHD_drv_video.so`.

```
tools/vaapi.sh --check     # is it all in place?
sudo tools/vaapi.sh        # driver and Firefox preferences
vainfo                     # supported profiles and entrypoints
```

If no Firefox profile exists yet, start Firefox once and re-run to pick up the
preferences. `sudo dnf install -y intel-media-driver` on its own is also fine if
you prefer to manage the driver yourself.

## Troubleshooting

- `tools/panel_fixes.sh --check` -- are the panel fixes configured?
- `journalctl -u iio-sensor-proxy` -- hinge angle, mode changes, `SW_TABLET_MODE`
- `journalctl --user -u minibook-rotation-fix.service` -- landscape corrections
- `busctl --system get-property net.hadess.SensorProxy /net/hadess/SensorProxy
  net.hadess.SensorProxy AccelerometerOrientation` -- should report an
  orientation such as `right-up`
- If `./install` warns that it cannot read the VBT, debugfs is needed: check that
  `/sys/kernel/debug` mounts and that `grubby` and `dracut` are installed
- SELinux: if a future `selinux-policy` drops the `iiosensorproxy_t` types the
  policy module is skipped and the service simply runs unconfined; denials can be
  turned into rules with `ausearch -m AVC -ts recent | audit2allow -M local`
- `acpi_call` is optional: without it the fork uses the calibration matrices from
  the ACPI `GMTR` tables and skips the EC `LTSM` call

## Credits

The dual-accelerometer driver is the fork by
[fstanis/chuwi-minibook](https://github.com/fstanis/chuwi-minibook), built on
[iio-sensor-proxy](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy). The
Fedora panel procedure comes from nfoulon-dev's `minibook-fix` scripts, and
`tools/vbt_patch.py` is a port of the VBT patcher in chuwi-minibook, and the
panel and video decode procedures come from the same minibook-fix scripts.

## License

0BSD, see [LICENSE](LICENSE).
