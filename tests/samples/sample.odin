package main

import "core:fmt"

// A point.
Point :: struct { x, y: int }

main :: proc() {
	p := Point{1, 2}
	/* print it */
	fmt.println(p, len("hi"), true, nil == nil)
}
