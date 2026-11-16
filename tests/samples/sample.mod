(* A greeting. *)
MODULE Hello;

FROM InOut IMPORT WriteString, WriteLn;

VAR count: INTEGER;

BEGIN
  count := 3;
  WriteString("Hello, world"); WriteLn
END Hello.
