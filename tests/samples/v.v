module main

import os

// A struct.
struct Point {
	x int
	y int
}

fn main() {
	p := Point{1, 2}
	println('point: ${p.x}, ${p.y}')
	println(os.args.len > 0 && true)
}
