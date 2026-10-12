#!/usr/bin/env python3
# SPDX-License-Identifier: 0BSD
"""
MiniBook X VBT patcher (pure Python, no build tools required).

Self-contained port of https://github.com/fstanis/chuwi-minibook (vbt_patch.c).
The MiniBook X's MIPI DSI panel is driven at 50 Hz by the Video BIOS Table
(VBT) that i915 reads at startup.  i915 will happily drive the panel faster if
we raise the pixel clock stored in the VBT's Generic DTD (block 58); the
patched VBT is then loaded at boot via the  i915.vbt_firmware=  kernel
parameter.  No firmware flash is involved and removing the parameter restores
the stock 50 Hz.

The VBT layout follows the kernel headers:
  drivers/gpu/drm/i915/display/intel_vbt_defs.h
  drivers/gpu/drm/i915/display/intel_dsi_vbt_defs.h

Usage:
  python3 vbt_patch.py <input_vbt>                     # print current state
  python3 vbt_patch.py <input> --hz 60 <output>        # patch refresh -> 60 Hz
  python3 vbt_patch.py <input> --hz 90 <output>        # patch refresh -> 90 Hz
  python3 vbt_patch.py <input> --rotation 3 <output>   # DSI rotation 0-3 (opt.)
  python3 vbt_patch.py <input> --hz 90 --rotation 3 <output>
"""

import argparse
import struct
import sys

# --- BDB block ids ---------------------------------------------------------
BDB_LFP_OPTIONS = 40
BDB_MIPI_CONFIG = 52
BDB_MIPI_SEQUENCE = 53
BDB_GENERIC_DTD = 58

ROTATION_NAMES = ["0 deg", "90 deg", "180 deg", "270 deg"]


# --- small helpers ---------------------------------------------------------
def u16(buf, off):
    return struct.unpack_from("<H", buf, off)[0]


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def find_vbt(data):
    """Return file offset of the '$VBT' signature or None."""
    i = data.find(b"$VBT")
    return i if i >= 0 else None


def find_block(buf, bdb_abs, avail, block_id):
    """Locate a BDB block, mirroring vbt_patch.c find_block() exactly.

    buf     : whole VBT bytearray
    bdb_abs : file offset where the BDB header starts
    avail   : bytes available from bdb_abs to end of file
    Returns the file offset of the block payload (i.e. after the 3-byte
    id/size header) or None.
    """
    header_size = u16(buf, bdb_abs + 18)  # struct bdb_header
    total = u16(buf, bdb_abs + 20)        # struct bdb_header.bdb_size
    if total > avail:
        total = avail
    index = header_size
    while index + 3 < total:
        bid = buf[bdb_abs + index]
        if bid == BDB_MIPI_SEQUENCE and buf[bdb_abs + index + 3] >= 3:
            size = u32(buf, bdb_abs + index + 4)
        else:
            size = u16(buf, bdb_abs + index + 1)
        index += 3
        if bid == block_id:
            return bdb_abs + index
        index += size
    return None


def fix_checksum(buf, vbt_off):
    """Recompute the VBT checksum byte (vbt_patch.c update_checksum())."""
    vbt_size = u16(buf, vbt_off + 24)
    buf[vbt_off + 26] = 0
    total = sum(buf[vbt_off:vbt_off + vbt_size]) & 0xFF
    buf[vbt_off + 26] = (0x100 - total) & 0xFF


# --- generic_dtd_entry (block 58) layout ----------------------------------
DTD_PIXEL_CLOCK = 0   # u32
DTD_HACTIVE     = 4   # u16
DTD_HBLANK      = 6   # u16
DTD_VACTIVE     = 12  # u16
DTD_VBLANK      = 14  # u16
DTD_SIZE        = 28  # sizeof(struct generic_dtd_entry)


def read_dtd(buf, entry_abs):
    pixel_clock = u32(buf, entry_abs + DTD_PIXEL_CLOCK)
    hactive = u16(buf, entry_abs + DTD_HACTIVE)
    hblank = u16(buf, entry_abs + DTD_HBLANK)
    vactive = u16(buf, entry_abs + DTD_VACTIVE)
    vblank = u16(buf, entry_abs + DTD_VBLANK)
    htotal = hactive + hblank
    vtotal = vactive + vblank
    refresh = (pixel_clock * 1000.0 / (htotal * vtotal)) if (htotal and vtotal) else 0.0
    return {
        "clock": pixel_clock,
        "hactive": hactive,
        "vactive": vactive,
        "htotal": htotal,
        "vtotal": vtotal,
        "refresh": refresh,
    }


def patch_vbt(data, hz=None, rotation=None):
    """Mutate a bytearray VBT in place. Returns a human-readable summary."""
    lines = []
    vbt_off = find_vbt(data)
    if vbt_off is None:
        raise SystemExit("error: '$VBT' signature not found in input")
    if u16(data, vbt_off + 22) < 40:  # header_size sanity
        raise SystemExit("error: VBT header looks wrong")

    bdb_off = vbt_off + u32(data, vbt_off + 28)
    avail = len(data) - bdb_off

    lfp = find_block(data, bdb_off, avail, BDB_LFP_OPTIONS)
    if lfp is None:
        raise SystemExit("error: BDB block 40 (LFP options) not found")
    panel = data[lfp]  # struct bdb_lfp_options.panel_type (first byte)

    dtd_blk = find_block(data, bdb_off, avail, BDB_GENERIC_DTD)
    if dtd_blk is None:
        raise SystemExit("error: BDB block 58 (Generic DTD) not found")

    entry_abs = dtd_blk + 2 + panel * DTD_SIZE  # struct bdb_generic_dtd {u16 gdtd_size; dtd[];}
    if entry_abs + DTD_SIZE > len(data):
        raise SystemExit(f"error: DTD entry for panel {panel} out of bounds")

    before = read_dtd(data, entry_abs)
    lines.append(f"Panel index     : {panel}")
    lines.append(f"Before          : {before['hactive']}x{before['vactive']} "
                 f"htotal={before['htotal']} vtotal={before['vtotal']} "
                 f"clock={before['clock']} kHz refresh={before['refresh']:.3f} Hz")

    # Safety gate: only touch data that looks like our portrait DSI panel.
    if not (1000 <= before["hactive"] <= 4000 and 1000 <= before["vactive"] <= 4000):
        raise SystemExit("error: decoded DTD does not look like a 1200x1920 panel; aborting")
    if not (15.0 <= before["refresh"] <= 200.0):
        raise SystemExit("error: decoded refresh out of range; aborting")

    changed = False

    if hz is not None:
        if hz <= 0:
            raise SystemExit("error: --hz must be positive")
        new_clock = hz * before["htotal"] * before["vtotal"] // 1000
        struct.pack_into("<I", data, entry_abs + DTD_PIXEL_CLOCK, new_clock)
        after = read_dtd(data, entry_abs)
        lines.append(f"After (--hz {hz}) : clock={new_clock} kHz "
                     f"refresh={after['refresh']:.3f} Hz")
        changed = True

    if rotation is not None:
        mipi = find_block(data, bdb_off, avail, BDB_MIPI_CONFIG)
        if mipi is None:
            raise SystemExit("error: BDB block 52 (MIPI config) not found")
        if panel != 0:
            raise SystemExit("error: --rotation currently supports panel index 0 only")
        # struct mipi_config: u16 panel_id, then General Params u32 where the
        # 2-bit 'rotation' field sits at bits 14-15.
        gen_off = mipi + 2
        val = u32(data, gen_off)
        old_rot = (val >> 14) & 0x3
        if rotation not in (0, 1, 2, 3):
            raise SystemExit("error: --rotation must be 0-3")
        val = (val & ~(0x3 << 14)) | ((rotation & 0x3) << 14)
        struct.pack_into("<I", data, gen_off, val)
        lines.append(f"DSI rotation    : {ROTATION_NAMES[old_rot]} -> "
                     f"{ROTATION_NAMES[rotation]}")
        changed = True

    if changed:
        fix_checksum(data, vbt_off)
        lines.append("VBT checksum    : updated")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="MiniBook X VBT patcher")
    ap.add_argument("input", help="path to the raw VBT blob")
    ap.add_argument("output", nargs="?", help="write patched VBT here")
    ap.add_argument("--hz", type=int, default=None, help="target refresh rate in Hz")
    ap.add_argument("--clock", type=int, default=None, help="target pixel clock in kHz")
    ap.add_argument("--rotation", type=int, default=None,
                    help="DSI panel rotation 0=0 1=90 2=180 3=270 (optional)")
    args = ap.parse_args()

    if args.hz is None and args.clock is None:
        args.clock = 0  # print-only mode

    with open(args.input, "rb") as fh:
        data = bytearray(fh.read())
    if not data:
        raise SystemExit("error: empty input file")

    # Locate the panel DTD once so --clock can write directly into it.
    vbt_off = find_vbt(data)
    if vbt_off is None:
        raise SystemExit("error: '$VBT' signature not found in input")
    bdb_off = vbt_off + u32(data, vbt_off + 28)
    avail = len(data) - bdb_off
    dtd_blk = find_block(data, bdb_off, avail, BDB_GENERIC_DTD)
    if dtd_blk is None:
        raise SystemExit("error: BDB block 58 (Generic DTD) not found")
    lfp = find_block(data, bdb_off, avail, BDB_LFP_OPTIONS)
    panel = data[lfp] if lfp is not None else 0
    entry_abs = dtd_blk + 2 + panel * DTD_SIZE

    if args.hz is not None:
        summary = patch_vbt(data, hz=args.hz, rotation=args.rotation)
    elif args.clock:
        before = read_dtd(data, entry_abs)
        struct.pack_into("<I", data, entry_abs + DTD_PIXEL_CLOCK, args.clock)
        after = read_dtd(data, entry_abs)
        fix_checksum(data, vbt_off)
        summary = (f"panel {panel}: clock {before['clock']} -> {after['clock']} kHz "
                   f"(refresh {before['refresh']:.3f} -> {after['refresh']:.3f} Hz)")
        if args.rotation is not None:
            summary += "\nnote: --rotation ignored with --clock (use --hz)"
    else:
        # Print-only: decode without changing anything.
        before = read_dtd(data, entry_abs)
        summary = (f"panel {panel}: {before['hactive']}x{before['vactive']} "
                   f"htotal={before['htotal']} vtotal={before['vtotal']} "
                   f"clock={before['clock']} kHz refresh={before['refresh']:.3f} Hz")

    print(summary)
    if args.output:
        with open(args.output, "wb") as fh:
            fh.write(data)
        print(f"Wrote {args.output} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
