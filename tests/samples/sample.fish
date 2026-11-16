#!/usr/bin/env fish
# Greet everyone.
function greet --argument name
    echo "Hello, $name" 'raw $x'
end

for n in ann bob
    greet $n
end
