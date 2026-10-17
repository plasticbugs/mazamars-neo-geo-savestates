#!/bin/sh
# Run MAME headless on a Neo Geo set from .mame/roms (symlinks to your own
# romsets; never committed), e.g.
#
#   tools/mame.sh mslug -bios unibios40 -seconds_to_run 30 -autoboot_script x.lua
#
# Nothing here may touch the display. MAME's defaults are fullscreen, and on
# macOS a fullscreen window moves the desktop to a new Space; `-video none`
# alone does not stop the window being created. So: SDL_VIDEODRIVER=dummy
# (read before MAME parses anything), -videodriver dummy, and -window
# -nomaximize in case a window is created anyway. Take pictures with
# snapshots, never by looking.
#
# Always pass -seconds_to_run, so a headless run cannot hang; this script adds
# a 600 s backstop if you forget.
root=$(cd "$(dirname "$0")/.." && pwd)
case " $* " in
    *" -seconds_to_run "*|*" -str "*) backstop= ;;
    *) backstop="-seconds_to_run 600" ;;
esac
mkdir -p "$root/.mame/cfg" "$root/.mame/nvram" "$root/.mame/snap" "$root/.mame/sta"
SDL_VIDEODRIVER=dummy \
exec mame -rompath "$root/.mame/roms" \
    -video none -videodriver dummy -window -nomaximize \
    -sound none -nothrottle -skip_gameinfo \
    -cfg_directory "$root/.mame/cfg" -nvram_directory "$root/.mame/nvram" \
    -snapshot_directory "$root/.mame/snap" -state_directory "$root/.mame/sta" \
    $backstop "$@"
