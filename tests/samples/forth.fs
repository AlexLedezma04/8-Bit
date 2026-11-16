\ Squares and sums.
: square ( n -- n*n ) dup * ;
: sum-squares ( a b -- n ) square swap square + ;
3 4 sum-squares . cr
." done" cr
