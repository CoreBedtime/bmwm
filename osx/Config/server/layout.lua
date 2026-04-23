local geometry = require("geometry")
local spring = require("spring")

local layout = {}

local FRAME_DT = 1 / 60
local FRAME_STIFFNESS = 80
local FRAME_DAMPING = 18
local MASTER_SWITCH_RATIO = 1.08
local PADDING = 32

local state = {
    master_key = nil,
    windows = {},
}

local function window_key(ref)
    return tostring(ref.Process) .. ":" .. tostring(ref.Window)
end

local function ensure_state(ref)
    local key = window_key(ref)
    local entry = state.windows[key]
    if entry == nil then
        entry = {
            vx = 0,
            vy = 0,
            vw = 0,
            vh = 0,
            x = nil,
            y = nil,
            width = nil,
            height = nil,
        }
        state.windows[key] = entry
    end

    return key, entry
end

local function prune_state(active)
    for key in pairs(state.windows) do
        if not active[key] then
            state.windows[key] = nil
        end
    end

    if state.master_key ~= nil and not active[state.master_key] then
        state.master_key = nil
    end
end

local function window_area(frame)
    return frame.width * frame.height
end

local function select_master(windows, active)
    local largest_key = nil
    local largest_area = -1
    local current_master_area = nil

    for i = 1, #windows do
        local ref = windows[i]
        local key = window_key(ref)
        active[key] = true

        local frame = GetFrame(ref)
        if frame ~= nil then
            local area = window_area(frame)
            if area > largest_area then
                largest_area = area
                largest_key = key
            end

            if key == state.master_key then
                current_master_area = area
            end
        end
    end

    local master_key = state.master_key
    if master_key ~= nil and not active[master_key] then
        master_key = nil
    end

    if master_key == nil or current_master_area == nil then
        master_key = largest_key
    elseif largest_key ~= nil and largest_key ~= master_key and largest_area > (current_master_area * MASTER_SWITCH_RATIO) then
        master_key = largest_key
    end

    if master_key == nil and #windows > 0 then
        master_key = window_key(windows[1])
    end

    state.master_key = master_key

    if master_key ~= nil then
        for i = 1, #windows do
            if window_key(windows[i]) == master_key then
                if i ~= 1 then
                    windows = MoveWindow(windows, i, 1)
                end
                break
            end
        end
    end

    return windows
end

local function target_layout(screen, count, index)
    if count == 1 then
        return geometry.inset(screen, PADDING)
    end

    local master_width = screen.width * 0.5
    local stack_width = screen.width - master_width
    local stack_count = count - 1
    local stack_height = screen.height / stack_count

    if index == 1 then
        return geometry.inset(
            geometry.rect(screen.x, screen.y, master_width, screen.height),
            PADDING
        )
    end

    local stack_index = index - 2
    return geometry.inset(
        geometry.rect(
            screen.x + master_width,
            screen.y + (stack_index * stack_height),
            stack_width,
            stack_height
        ),
        PADDING
    )
end

-- Use the last applied frame so relayouts start from what was actually shown.
local function current_frame_for(ref, target_frame, anim)
    if anim.x ~= nil and anim.y ~= nil and anim.width ~= nil and anim.height ~= nil then
        return geometry.rect(anim.x, anim.y, anim.width, anim.height)
    end

    local frame = GetFrame(ref)
    if frame == nil
        or type(frame.width) ~= "number" or frame.width <= 0
        or type(frame.height) ~= "number" or frame.height <= 0 then
        anim.x = target_frame.x
        anim.y = target_frame.y
        anim.width = target_frame.width
        anim.height = target_frame.height
        return target_frame
    end

    anim.x = frame.x
    anim.y = frame.y
    anim.width = frame.width
    anim.height = frame.height
    return frame
end

function layout.apply(windows)
    local count = #windows
    if count == 0 then
        return
    end

    local active = {}
    windows = select_master(windows, active)

    local screen = ScreenFrame()

    for i = 1, count do
        local ref = windows[i]
        local key, anim = ensure_state(ref)
        active[key] = true

        local target_frame = target_layout(screen, count, i)
        local current_frame = current_frame_for(ref, target_frame, anim)

        local next_x
        next_x, anim.vx = spring.step(current_frame.x, anim.vx, target_frame.x, FRAME_STIFFNESS, FRAME_DAMPING, FRAME_DT)

        local next_y
        next_y, anim.vy = spring.step(current_frame.y, anim.vy, target_frame.y, FRAME_STIFFNESS, FRAME_DAMPING, FRAME_DT)

        local next_width
        next_width, anim.vw = spring.step(current_frame.width, anim.vw, target_frame.width, FRAME_STIFFNESS, FRAME_DAMPING, FRAME_DT)

        local next_height
        next_height, anim.vh = spring.step(current_frame.height, anim.vh, target_frame.height, FRAME_STIFFNESS, FRAME_DAMPING, FRAME_DT)

        anim.x = next_x
        anim.y = next_y
        anim.width = math.max(1, next_width)
        anim.height = math.max(1, next_height)

        SetFrame(ref, geometry.rect(
            anim.x,
            anim.y,
            anim.width,
            anim.height
        ))
    end

    prune_state(active)
end

return layout
