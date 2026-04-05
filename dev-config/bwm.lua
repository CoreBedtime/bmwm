local source = debug.getinfo(1, "S").source
local config_dir = source:match("^@(.*/)") or "./"

return {
    root_color = 0xFF1B1D1F,
    -- Optional. Set this to an image path if you want a wallpaper-backed root window.
    -- root_image = config_dir .. "wallpaper.png",
    titlebar_color = 0xFF2A2E34,
    titlebar_focus_color = 0xFF3B82F6,
}
