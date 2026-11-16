import 'dart:math';

/// A point.
class Point {
  final double x, y;
  const Point(this.x, this.y);

  double get length => sqrt(x * x + y * y); // size
}

void main() {
  var p = Point(3, 4);
  print("length: ${p.length}");
  final text = '''two
lines''';
  print(text.isEmpty ? null : true);
}
