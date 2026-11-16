package;

// The program.
class Main {
    static function main() {
        var names:Array<String> = ["ann", 'bob'];
        /* show them */
        for (n in names) trace('Hello, $n');
        trace(names.length > 0 && true, null);
    }
}
