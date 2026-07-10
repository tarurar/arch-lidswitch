local source = debug.getinfo(1, "S").source
local module_path = source:match("^@(.+)$")
local config_dir = module_path and module_path:match("^(.*)/arch_lidswitch/session%.lua$")

if not config_dir then
    error("arch-lidswitch: unable to locate the Hyprland configuration directory")
end

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local bridge = shell_quote(config_dir .. "/scripts/lid-session-bridge.sh")

hl.on("hyprland.start", function()
    hl.exec_cmd(bridge .. " start")
end)

hl.on("hyprland.shutdown", function()
    os.execute(bridge .. " stop")
end)

return true
