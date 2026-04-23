local function configure_package_path()
    local source = debug.getinfo(1, "S").source
    if type(source) ~= "string" then
        return
    end

    local script_path = source:sub(1, 1) == "@" and source:sub(2) or source
    local script_dir = script_path:match("(.*/)")
    if script_dir == nil then
        return
    end

    package.path = table.concat({
        script_dir .. "?.lua",
        script_dir .. "?/init.lua",
        package.path,
    }, ";")
end

configure_package_path()

local layout = require("layout")

function WindowManagerCallback()
    layout.apply(GatherWindows())
end
