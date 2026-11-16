# A procedure.
proc greet {name} {
    set msg "Hello, $name"
    puts $msg
    return [string length $msg]
}

foreach n {ann bob} { greet $n }
