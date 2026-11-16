**FREE
// A greeting.
dcl-s name varchar(10) inz('world');
dcl-s count int(10);

for count = 1 to 3;
  dsply ('Hello, ' + %trim(name));
endfor;

*inlr = *on;
