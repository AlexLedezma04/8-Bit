#[ A block
comment. ]#
import std/strutils

type Point = object
  x, y: int

proc show(p: Point): string =
  result = "(" & $p.x & ", " & $p.y & ")"  # format

echo show(Point(x: 1, y: 2)), true, nil == nil
