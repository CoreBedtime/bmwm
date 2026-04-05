local source = debug.getinfo(1, "S").source
local config_dir = source:match("^@(.*/)") or "./"

return {
    background_color = 0xFFF0F0F0,
    -- Optional. Set this to an image path if you want a wallpaper-backed root window.
    -- background_image = config_dir .. "wallpaper.png",
    titlebar_color = 0xFF2A2E34,
    titlebar_focus_color = 0xFF3B82F6,
}
