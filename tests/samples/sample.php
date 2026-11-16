<?php
// A function.
function greet(string $name): string {
    /* build */
    return "Hello, " . $name;
}

echo greet('world'), true, null;
