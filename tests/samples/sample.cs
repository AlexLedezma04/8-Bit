using System;

namespace Demo
{
    /* A record. */
    public record Point(int X, int Y);

    public static class Program
    {
        public static void Main(string[] args)
        {
            var p = new Point(1, 2); // make one
            Console.WriteLine($"x = {p.X}");
            string path = @"C:\temp";
        }
    }
}
