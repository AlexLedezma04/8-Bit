program Hello;

{ A block comment. }
(* Another kind. *)
uses SysUtils;

var
  Count: Integer;

begin
  Count := 3; // three
  WriteLn('Hello, world ', Count, True);
end.
