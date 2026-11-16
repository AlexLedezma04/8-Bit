module Sample

(* A block comment. *)
type Shape =
    | Circle of float
    | Square of float

// Area of a shape.
let area shape =
    match shape with
    | Circle r -> System.Math.PI * r * r
    | Square s -> s * s

printfn "%f %b" (area (Circle 1.0)) true
