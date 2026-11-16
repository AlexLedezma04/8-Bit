with Ada.Text_IO; use Ada.Text_IO;

-- A greeting.
procedure Hello is
   Count : Integer := 3;
begin
   for I in 1 .. Count loop
      Put_Line ("Hello");
   end loop;
end Hello;
