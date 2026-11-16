module Main exposing (main)

import Html exposing (text)

{-| Says hello. -}
greet : String -> String
greet name =
    "Hello, " ++ name -- concat

main =
    text (greet "world")
