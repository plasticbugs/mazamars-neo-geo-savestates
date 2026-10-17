#!/usr/bin/env python3
"""Check a Darksoft game folder against the ROM regions MAME loads for the set.

    REGION_DIR=build/regions/<set> tools/mame.sh <set> -seconds_to_run 1 \
        -autoboot_script tools/dump_regions.lua
    tools/check_darksoft.py build/regions/<set> <darksoft folder>

The core loads Darksoft files (see data.json). Against MAME's regions, as
dump_regions.lua reads them:
  prom    the 68k program region, which Lua reads in the CPU's big-endian
          order; the core takes it in ROM-file order (little-endian words,
          like the BIOS file), so each word's bytes are swapped
  srom    the fix region as it is
  m1rom   the audio region from 0x10000: MAME puts the first 64 KB of M1 in
          front of the whole of it
  vroma0  the ADPCM region as it is (V1, V2, ... in order)
  crom0   the sprite region (C1/C2 interleaved a byte at a time) with the
          middle two bytes of every four swapped, so each 32-bit group is a
          C1 word then a C2 word: the conversion MiSTer's loader applies to
          .neo files to match crom0 (spr_bswap in Main_MiSTer
          support/neogeo/neogeo_loader.cpp)
Encrypted (CMC/PCM2/SMA/PVC) sets are not covered: MAME decrypts at load.
"""
import os
import sys

regions, folder = sys.argv[1], sys.argv[2]


def region(name):
    return open(os.path.join(regions, name + ".bin"), "rb").read()


def swap16(b):
    out = bytearray(b)
    out[0::2], out[1::2] = b[1::2], b[0::2]
    return bytes(out)


def crom_from_sprites(spr):
    out = bytearray(spr)
    out[1::4], out[2::4] = spr[2::4], spr[1::4]
    return bytes(out)


expect = {
    "prom": swap16(region("cslot1_maincpu")),
    "srom": region("cslot1_fixed"),
    "m1rom": region("cslot1_audiocpu")[0x10000:],
    "vroma0": region("cslot1_ymsnd_adpcma"),
    "crom0": crom_from_sprites(region("cslot1_sprites")),
}

bad = 0
for name, want in expect.items():
    path = os.path.join(folder, name)
    if not os.path.exists(path):
        print(f"MISSING {name}")
        bad += 1
        continue
    got = open(path, "rb").read()
    if got == want:
        print(f"ok      {name:7s} {len(got):9d} bytes")
        continue
    bad += 1
    first = next((i for i in range(min(len(got), len(want))) if got[i] != want[i]), None)
    print(f"DIFFER  {name:7s} {len(got)} bytes, MAME {len(want)}; first difference at "
          f"{first if first is None else hex(first)}")
sys.exit(1 if bad else 0)
