package main

import "fmt"

// Point is a point.
type Point struct{ X, Y int }

func main() {
    p := Point{1, 2}
    s := `raw
string`
    fmt.Println(p, len(s), nil == nil)
}
