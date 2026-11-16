# A loop in ALGOL 68. #
BEGIN
  INT sum := 0;
  FOR i FROM 1 TO 10 DO
    sum +:= i
  OD;
  print(("sum: ", sum, TRUE))
END
