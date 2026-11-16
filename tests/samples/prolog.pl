% Family facts.
parent(tom, bob).
parent(bob, ann).

/* grandparents */
grandparent(X, Z) :- parent(X, Y), parent(Y, Z).

:- initialization(main).
main :- grandparent(tom, Who), format("~w~n", [Who]).
