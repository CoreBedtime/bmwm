local geometry = {}

function geometry.rect(x, y, width, height)
    return {
        x = x,
        y = y,
        width = width,
        height = height,
    }
end

function geometry.inset(frame, amount)
    return geometry.rect(
        frame.x + amount,
        frame.y + amount,
        frame.width - (amount * 2),
        frame.height - (amount * 2)
    )
end

return geometry
