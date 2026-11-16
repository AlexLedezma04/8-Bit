#= A module.
   Two lines. =#
module Shapes

export area

struct Circle
    r::Float64
end

area(c::Circle) = pi * c.r^2  # formula
@show area(Circle(2.0)), true, nothing
end
