import std.stdio;

/+ A nested
   comment. +/
struct Point { int x, y; }

/// Entry point.
void main()
{
    auto p = Point(1, 2);
    string raw = `raw
text`;
    writeln(p.x + p.y, " ", raw.length, true, null is null);
}
