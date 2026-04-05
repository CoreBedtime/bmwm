local source = debug.getinfo(1, "S").source
local config_dir = source:match("^@(.*/)") or "./"

return {
    background_image = "/Volumes/Bedtime/Developer/Applicator/dev-config/wall.png",
    titlebar_color = 0xFF2A2E34,
    titlebar_focus_color = 0xFF3B82F6,
}
