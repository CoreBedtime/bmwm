local source = debug.getinfo(1, "S").source
local config_dir = source:match("^@(.*/)") or "./"

background_image(config_dir .. "wall.png")

titlebar_color(0xFF2A2E34)
titlebar_focus_color(0xFF3B82F6)

shadow_enabled(true)
shadow_x_offset(6)
shadow_y_offset(6)
shadow_spread(8)
shadow_opacity(52)
shadow_color(0xFF0E0F11)
