:- module hello.
:- interface.
:- import_module io.

% The entry point.
:- pred main(io::di, io::uo) is det.

:- implementation.
main(!IO) :-
    io.write_string("Hello, world\n", !IO).
