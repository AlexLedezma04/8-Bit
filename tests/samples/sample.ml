(* A module. *)
type shape = Circle of float | Square of float

let area = function
  | Circle r -> 3.14 *. r *. r
  | Square s -> s *. s

let () = Printf.printf "%f %b\n" (area (Circle 1.0)) true
