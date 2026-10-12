#!/usr/bin/env python3
# SPDX-License-Identifier: 0BSD
"""Keep the MiniBook X built-in panel in landscape while the lid is unfolded.

When the SW_TABLET_MODE switch turns off, mutter resets the built-in panel to its
panel-orientation default. Because i915 already advertises landscape modes for this
270-degree mounted panel, the kernel's panel_orientation is applied a second time and
the desktop lands in portrait. While the switch is off (unfolded) this re-applies
landscape; while it is on, mutter's own auto-rotation is correct and left alone.
"""

import fcntl
import os
import struct
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

DISPLAY_CONFIG = (
    "org.gnome.Mutter.DisplayConfig",
    "/org/gnome/Mutter/DisplayConfig",
    "org.gnome.Mutter.DisplayConfig",
)
SENSOR_PROXY = ("net.hadess.SensorProxy", "/net/hadess/SensorProxy")

SWITCH_NAME = "MXC6655 Tablet Mode Control"
EV_SW = 0x05
SW_TABLET_MODE = 0x01
EVENT_SIZE = 24
EVIOCGSW = 0x8008451B  # _IOC(_IOC_READ, 'E', 0x1b, sizeof(long))

LANDSCAPE = 0
PORTRAIT_TRANSFORMS = (1, 3)
RETRY_SECONDS = 10
DEBOUNCE_MS = 250
# Ignore a fresh "unfolded" reading that is younger than this: near the fold
# threshold the hinge report can flap, and acting on it would fight mutter.
SETTLE_SECONDS = 1.0


def log(message):
    print(message, flush=True)


class MinibookRotationFix:
    def __init__(self):
        self.session_bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.switch_fd = None
        self.switch_folded = None
        self.switch_changed_at = 0.0
        self.check_id = 0

        self.session_bus.signal_subscribe(
            DISPLAY_CONFIG[0], DISPLAY_CONFIG[2], "MonitorsChanged", DISPLAY_CONFIG[1],
            None, Gio.DBusSignalFlags.NONE, self.schedule_check)
        self.system_bus.signal_subscribe(
            SENSOR_PROXY[0], "org.freedesktop.DBus.Properties", "PropertiesChanged",
            SENSOR_PROXY[1], None, Gio.DBusSignalFlags.NONE, self.schedule_check)

        self.watch_switch()
        GLib.timeout_add_seconds(RETRY_SECONDS, self.watch_switch)

    def watch_switch(self):
        if self.switch_fd is None:
            path = self.find_switch()
            if path is None:
                log("tablet-mode switch not present, will retry")
            else:
                try:
                    self.switch_fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                except OSError as err:
                    log(f"cannot open {path}: {err}")
                    self.switch_fd = None
                else:
                    log(f"watching tablet-mode switch {path}")
                    self.switch_folded = self.read_switch_bit()
                    self.switch_changed_at = time.monotonic()
                    GLib.io_add_watch(
                        self.switch_fd,
                        GLib.IOCondition.IN | GLib.IOCondition.HUP | GLib.IOCondition.ERR,
                        self.on_switch_event)
                    self.schedule_check()
        return True

    @staticmethod
    def find_switch():
        for entry in sorted(os.listdir("/sys/class/input")):
            if not entry.startswith("event"):
                continue
            try:
                with open(f"/sys/class/input/{entry}/device/name") as name_file:
                    if name_file.read().strip() == SWITCH_NAME:
                        return f"/dev/input/{entry}"
            except OSError:
                continue
        return None

    def on_switch_event(self, fd, condition):
        if condition & (GLib.IOCondition.HUP | GLib.IOCondition.ERR | GLib.IOCondition.NVAL):
            log("tablet-mode switch disappeared, will retry")
            os.close(fd)
            self.switch_fd = None
            self.switch_folded = None
            return False
        try:
            data = os.read(fd, EVENT_SIZE * 64)
        except OSError:
            data = b""
        for offset in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
            _sec, _usec, type_, code, value = struct.unpack_from("llHHi", data, offset)
            if type_ == EV_SW and code == SW_TABLET_MODE:
                self.set_folded(bool(value))
        self.schedule_check()
        return True

    def set_folded(self, folded):
        if folded != self.switch_folded:
            log(f"tablet mode {'on (folded)' if folded else 'off (unfolded)'}")
            self.switch_folded = folded
        self.switch_changed_at = time.monotonic()

    def read_switch_bit(self):
        if self.switch_fd is None:
            return None
        state = bytearray(8)
        try:
            fcntl.ioctl(self.switch_fd, EVIOCGSW, state, True)
        except OSError:
            return None
        return bool(struct.unpack("Q", state)[0] & SW_TABLET_MODE)

    def folded(self):
        """True/False, or None while the switch state is unknown."""
        if self.switch_fd is None:
            return None
        # The event stream is authoritative; a set switch bit also counts, so a
        # missed event can never make us fight mutter's rotation while folded.
        if self.read_switch_bit():
            return True
        return self.switch_folded

    def schedule_check(self, *_args):
        if not self.check_id:
            self.check_id = GLib.timeout_add(DEBOUNCE_MS, self.check)

    def check(self):
        self.check_id = 0
        if self.folded() is not False:
            return GLib.SOURCE_REMOVE
        if time.monotonic() - self.switch_changed_at < SETTLE_SECONDS:
            self.schedule_check()
            return GLib.SOURCE_REMOVE
        try:
            self.ensure_landscape()
        except GLib.Error as err:
            log(f"mutter call failed: {err.message}")
        except Exception as err:  # keep the daemon alive on unexpected errors
            log(f"check failed: {err!r}")
        return GLib.SOURCE_REMOVE

    def ensure_landscape(self):
        state = self.session_bus.call_sync(
            DISPLAY_CONFIG[0], DISPLAY_CONFIG[1], DISPLAY_CONFIG[2], "GetCurrentState",
            None, None, Gio.DBusCallFlags.NONE, -1, None)
        serial, monitors, logical, _properties = state.unpack()

        modes = {}
        builtin = set()
        for spec, mode_list, monitor_props in monitors:
            if monitor_props.get("is-builtin"):
                builtin.add(spec[0])
            for mode in mode_list:
                mode_id, _width, _height, _refresh, _scale, _scales, mode_props = mode
                if mode_props.get("is-current"):
                    modes[spec[0]] = mode_id
        if not builtin:
            return

        fix_needed = False
        new_logical = []
        for x, y, scale, transform, primary, specs, _props in logical:
            panel = [spec[0] for spec in specs if spec[0] in builtin]
            if panel and transform in PORTRAIT_TRANSFORMS:
                if all(is_landscape_mode(modes.get(name)) for name in panel):
                    log(f"panel is portrait (transform {transform}) while unfolded, "
                        "re-applying landscape")
                    transform = LANDSCAPE
                    fix_needed = True
            new_logical.append(
                (x, y, scale, transform, primary,
                 [(spec[0], modes[spec[0]], {}) for spec in specs]))

        if not fix_needed:
            return
        params = GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (serial, 1, new_logical, {}))
        self.session_bus.call_sync(
            DISPLAY_CONFIG[0], DISPLAY_CONFIG[1], DISPLAY_CONFIG[2], "ApplyMonitorsConfig",
            params, None, Gio.DBusCallFlags.NONE, -1, None)


def is_landscape_mode(mode_id):
    if not mode_id:
        return False
    try:
        width, height = (int(part) for part in mode_id.split("@")[0].split("x"))
    except ValueError:
        return False
    return width >= height


def main():
    fix = MinibookRotationFix()  # noqa: F841  (kept alive for the main loop)
    fix.schedule_check()
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
