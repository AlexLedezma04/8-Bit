;; Adds two numbers.
(module
  (; a block comment ;)
  (func $add (export "add") (param $a i32) (param $b i32) (result i32)
    local.get $a
    local.get $b
    i32.add)
  (memory 1))
