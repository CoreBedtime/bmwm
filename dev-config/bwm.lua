local source = debug.getinfo(1, "S").source
local config_dir = source:match("^@(.*/)") or "./"

x11_width(1800)
x11_height(1169)
background_image(config_dir .. "wall.png")

-- x11_width = 3440
-- x11_height = 1440
-- background_color(0xFF3773C3)

titlebar_color(0xFF2A2E34)
titlebar_focus_color(0xFF3B82F6)

shadow_enabled(true)
shadow_x_offset(0)
shadow_y_offset(0)
shadow_spread(8)
shadow_opacity(52)
shadow_color(0xFF0E0F11)
