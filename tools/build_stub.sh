#!/bin/sh
# Assemble the 68000 savestate stub into the 16-bit hex image ss_m68k loads
# with $readmemh (one big-endian word per line, 512 words). The .hex is
# committed, so the core builds without an assembler.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/src/NeoGeo Cart/core/NeoGeoCore/savestate"
tmp=$(mktemp -d)
m68k-elf-as -m68000 --register-prefix-optional -o "$tmp/stub.o" "$dir/ss68k_stub.s"
m68k-elf-objcopy -O binary -j .text "$tmp/stub.o" "$tmp/stub.bin"
python3 -I - "$tmp/stub.bin" "$dir/ss68k_stub.hex" <<'EOF'
import sys
code = open(sys.argv[1], "rb").read()
words = 512
if len(code) > words * 2:
    sys.exit(f"stub is {len(code)} bytes, more than {words * 2}")
code += b"\x4e\x71" * ((words * 2 - len(code)) // 2)       # NOP padding
with open(sys.argv[2], "w") as f:
    for i in range(0, len(code), 2):
        f.write(f"{code[i] << 8 | code[i + 1]:04x}\n")
print(f"stub: {len(code)} bytes image, {open(sys.argv[1], 'rb').read().__len__()} of code")
EOF
m68k-elf-objdump -d "$tmp/stub.o" | sed -n '/<entry>/,$p'
rm -rf "$tmp"
