-module(sample).
-export([start/0]).

%% Adds two numbers.
add(A, B) -> A + B.

start() ->
    io:format("~p~n", [add(1, 2)]),
    {ok, 'quoted atom', true}.
