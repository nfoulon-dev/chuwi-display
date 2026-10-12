# chuwi-fold

Fold detection for the CHUWI MiniBook X on Fedora.

Fold the display back past 185 degrees — fully folded *or* in tent mode — and
the internal keyboard, touchpad and pointer are suspended. Unfold, and they
come back immediately with the panel returning to landscape.

Tested on a MiniBook X (Intel N150) with Fedora 44, GNOME 50 on Wayland,
libinput 1.31.3, kernel 7.2.9.

## Why this is needed

The MiniBook X reports no tablet-mode switch at all:

- no `SW_TABLET_MODE` device exists, only the lid switch,
- ACPI `_SB.CONV` (`INT33D3`) is a stub with no `_CRS`, so nothing binds to it,
- the vendor's own slate detection (`_SB.ACMK.LTSM` -> EC `KBCD`) is never
  called by firmware; it is a hook for the Windows sensor driver, which decides
  from the accelerometer angle.

So the hinge angle has to be derived in software.

## How it works

1. **Hinge angle.** Two MXC6655 accelerometers sit behind one ACPI device
   (`MDA6655`); only one is visible through IIO. The forked `iio-sensor-proxy`
   in [patches/](patches) reads both over raw I2C, computes the hinge angle from
   the gravity vectors, and publishes `SW_TABLET_MODE` on a uinput device once
   the angle stays above 185 degrees for 250 ms (175 degrees to come back).
   libinput pairs that switch with the internal keyboard and touchpad and
   suspends them, which is also what raises the on-screen keyboard.
2. **Panel orientation.** On leaving tablet mode mutter resets the built-in
   panel to the DRM panel-orientation default. On this panel — mounted rotated
   270 degrees, with landscape modes already advertised by i915 — that default
   is portrait, so the desktop stays rotated after unfolding. The user daemon
   in [files/minibook-rotation-fix.py](files/minibook-rotation-fix.py) reapplies
   landscape whenever the switch is off, and does nothing while it is on, so
   GNOME's own auto-rotation is untouched in tablet and tent mode.

## Install

```
git clone https://github.com/nfoulon-dev/chuwi-fold.git
cd chuwi-fold
./install
```

`./install` elevates itself with sudo, installs the build dependencies
(`meson`, `ninja-build`, `glib2-devel`, `libdrm-devel`, `polkit-devel`,
`systemd-devel`, `libgudev-devel`, `git` and the SELinux tools), clones
[fstanis/chuwi-minibook](https://github.com/fstanis/chuwi-minibook),
applies [patches/](patches), builds, and installs everything below. It needs
network access and is safe to re-run.

Useful overrides:

- `CHUWI_MINIBOOK=/path/to/chuwi-minibook ./install` — use an existing checkout
- `IIO_BINARY=/path/to/iio-sensor-proxy ./install` — skip source and build
- `DESTDIR=/tmp/x ./install` — install into a prefix, no system changes

## What gets installed

| Path | What |
| --- | --- |
| `/usr/local/libexec/iio-sensor-proxy` | the forked sensor proxy (not owned by the package) |
| `/etc/systemd/system/iio-sensor-proxy.service` | starts that binary |
| `/etc/systemd/system/iio-sensor-proxy.service.d/panel.conf` | disables the fork's panel compensation when the kernel already applies it |
| `/etc/udev/rules.d/70-minibook-rotation-fix.rules` | gives the session user read access to the switch device |
| SELinux module `minibook_iio_sensor_proxy` | lets the confined service read both i2c accelerometers, DRM and uinput |
| `~/.local/bin/minibook-rotation-fix.py` | landscape daemon |
| `~/.config/systemd/user/minibook-rotation-fix.service` | starts it with the session |

Nothing installed here is owned by the `iio-sensor-proxy` package, so
`dnf upgrade` cannot break the setup.

## Panel prerequisites

The MiniBook's panel is mounted rotated, and the kernel-side fixes from the
[chuwi-minibook](https://github.com/fstanis/chuwi-minibook) repository (VBT
patch plus `i915.vbt_firmware=vbt`, `video=DSI-1:panel_orientation=right_side_up`,
`fbcon=rotate:1`) are what make it come up landscape. `./install` detects that
and only then disables the fork's own panel compensation, which would otherwise
rotate the output twice. If you see the warning about a missing
`panel_orientation` argument, apply those fixes first — see `GUIDE.md` there.

## Uninstall

```
cd chuwi-fold
./uninstall
```

This removes the files above, drops the SELinux module and reinstalls the
distribution's `iio-sensor-proxy` so the stock sensor stack works again.
No reboot is needed either way.

## Troubleshooting

- `journalctl -u iio-sensor-proxy` — hinge angle, mode changes, `SW_TABLET_MODE`
- `journalctl --user -u minibook-rotation-fix.service` — landscape corrections
- `busctl --system get-property net.hadess.SensorProxy /net/hadess/SensorProxy \
  net.hadess.SensorProxy AccelerometerOrientation` — should report an
  orientation such as `right-up`
- SELinux: if a future `selinux-policy` drops the `iiosensorproxy_t` types the
  policy module is skipped and the service simply runs unconfined; denials can
  be turned into rules with `ausearch -m AVC -ts recent | audit2allow -M local`
- `acpi_call` is optional: without it the fork uses the built-in calibration
  matrices from the ACPI `GMTR` tables and skips the EC `LTSM` call

## Credits

The dual-accelerometer driver is the fork by
[fstanis/chuwi-minibook](https://github.com/fstanis/chuwi-minibook), built on
[iio-sensor-proxy](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy).
The two driver fixes in [patches/](patches) are described in the patch message.

## License

0BSD, see [LICENSE](LICENSE).
