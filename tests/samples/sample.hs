{- A module. -}
module Main where

import Data.List (sort)

-- | Doubles every number.
double :: [Int] -> [Int]
double xs = map (*2) xs

main :: IO ()
main = print (sort (double [3, 1, 2]), Just True)
