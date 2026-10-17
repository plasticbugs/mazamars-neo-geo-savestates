-- Dump every ROM region MAME has loaded for the running set to
-- $REGION_DIR/<tag>.bin (':' in tags becomes '_'), as the chips see them.
-- tools/check_darksoft.py compares a Darksoft folder against these.
local dir = os.getenv("REGION_DIR") or "."
_G.KEEP = {}
_G.KEEP.s = emu.add_machine_stop_notifier(function() end)
for tag, r in pairs(manager.machine.memory.regions) do
  local f = io.open(dir .. "/" .. tag:gsub("^:", ""):gsub(":", "_") .. ".bin", "wb")
  for i = 0, r.size - 1 do f:write(string.char(r:read_u8(i))) end
  f:close()
  print(string.format("%-28s %9d", tag, r.size))
end
