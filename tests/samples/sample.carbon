package Sample api;

// A class.
class Point {
  var x: i32;
  var y: i32;
}

fn Add(a: i32, b: i32) -> i32 {
  return a + b;
}

fn Main() -> i32 {
  var p: Point = {.x = 1, .y = 2};
  return Add(p.x, p.y);
}
