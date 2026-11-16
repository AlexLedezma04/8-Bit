-- A counter.
library ieee;
use ieee.std_logic_1164.all;

entity counter is
  port (clk : in std_logic; q : out integer);
end entity;

architecture rtl of counter is
begin
  q <= 0 when clk = '1' else 1;
end architecture;
