local spring = {}

function spring.step(value, velocity, target, stiffness, damping, dt)
    local acceleration = (target - value) * stiffness - (velocity * damping)
    velocity = velocity + (acceleration * dt)
    value = value + (velocity * dt)
    return value, velocity
end

return spring
