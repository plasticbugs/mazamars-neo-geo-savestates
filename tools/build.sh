#!/bin/sh
# Compile the core with Quartus 18.1 in Docker (raetro/quartus:pocket), from a
# clean copy of the working tree, so the Quartus databases never land in src/.
#
#   tools/build.sh            full compile, then bit-reverse to build/Core.rbf_r
#   tools/build.sh map        analysis & synthesis only
#
# Output: build/<flow>/src/NeoGeo Cart/output_files/ (reports) and
# build/Core.rbf_r (the file the Pocket loads, named as core.json expects).
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
FLOW=${1:-compile}
case "$FLOW" in
    map)     CMD="quartus_map --parallel=1 --read_settings_files=on ap_core.qpf -c ap_core" ;;
    # Synthesis on one thread: its parallel helpers die under x86 emulation
    # and leave quartus_map waiting on their pipes forever (seen twice, idle
    # for hours). The fitter and timing keep the .qsf's threads.
    compile) CMD="quartus_map --parallel=1 --read_settings_files=on ap_core -c ap_core &&
                  quartus_fit --read_settings_files=on ap_core -c ap_core &&
                  quartus_asm ap_core -c ap_core &&
                  quartus_sta ap_core -c ap_core" ;;
    *) echo "usage: $0 [map|compile]"; exit 2 ;;
esac
work="$root/build/$FLOW"
rm -rf "$work"
mkdir -p "$work"
# Tracked files plus any new, unignored ones: what the commit would contain.
(cd "$root" && git ls-files -z --cached --others --exclude-standard -- src) |
    (cd "$root" && xargs -0 tar cf -) | (cd "$work" && tar xf -)
docker run --rm --platform linux/amd64 \
    -v "$work/src/NeoGeo Cart":/build -w /build \
    raetro/quartus:pocket \
    sh -c "$CMD"
if [ "$FLOW" = compile ]; then
    python3 -I - "$work/src/NeoGeo Cart/output_files/ap_core.rbf" "$root/build/Core.rbf_r" <<'EOF'
import sys
rev = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
data = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(bytes(rev[b] for b in data))
print(f"wrote {sys.argv[2]} ({len(data)} bytes)")
EOF
    grep -A3 -i 'slack' "$work/src/NeoGeo Cart/output_files/ap_core.sta.summary" | head -40 || true
fi
