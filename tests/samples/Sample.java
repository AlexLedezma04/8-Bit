package demo;

import java.util.List;

/** A greeter. */
public class Sample {
    @Override
    public String toString() {
        return "Sample"; // name
    }

    public static void main(String[] args) {
        List<Integer> xs = List.of(1, 2, 3);
        char c = 'a';
        System.out.println(xs.size() + c);
    }
}
