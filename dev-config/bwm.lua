local source = debug.getinfo(1, "S").source
local config_dir = source:match("^@(.*/)") or "./"

local function env_u16(name, fallback)
    local value = os.getenv(name)
    if value == nil or value == "" then
        return fallback
    end

    local parsed = tonumber(value)
    if parsed == nil then
        return fallback
    end

    parsed = math.floor(parsed)
    if parsed < 1 or parsed > 65535 then
        return fallback
    end

    return parsed
end

local framebuffer_width = env_u16("APPLICATOR_FRAMEBUFFER_WIDTH", 3024)
local framebuffer_height = env_u16("APPLICATOR_FRAMEBUFFER_HEIGHT", 1964)

-- The render server exports the selected framebuffer size, so the X11 root
-- matches the framebuffer instead of staying pinned to the top-left corner.
x11_width(framebuffer_width)
x11_height(framebuffer_height)
background_image(config_dir .. "wall.png")

-- background_color(0xFF3773C3)

titlebar_color(0xFF2A2E34)
titlebar_focus_color(0xFF3B82F6)

shadow_enabled(true)
shadow_x_offset(0)
shadow_y_offset(0)
shadow_spread(8)
shadow_opacity(52)
shadow_color(0xFF0E0F11)
