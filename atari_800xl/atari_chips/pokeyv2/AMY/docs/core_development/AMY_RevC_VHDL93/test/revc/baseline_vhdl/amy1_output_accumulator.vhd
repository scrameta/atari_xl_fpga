-------------------------------------------------------------------------------
-- AMY1 output accumulator: sums the sine values into samples. See AMY1_SPEC.md 4.6.
--
-- Every chip clock it adds one sine value: acc = acc + hs. hs is in ones' complement
-- form for negative values (sine_rom), so a carry-in of 1 is added when hs is negative,
-- making the sum exact two's complement. On load the total is latched as the sample and
-- the sum restarts from this clock's hs.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_output_accumulator is
  port (
    clk    : in  std_logic;
    ce     : in  std_logic;                      -- chip clock enable: registers update
    hs     : in  std_logic_vector(12 downto 0);  -- sine value (sine_rom)
    load   : in  std_logic;                      -- latch the sample, restart the sum
    sample : out signed(16 downto 0)             -- the last sample, two's complement
  );
end entity;

architecture rtl of amy1_output_accumulator is

  signal acc_reg,   acc_next   : signed(16 downto 0) := (others => '0');
  signal latch_reg, latch_next : signed(16 downto 0) := (others => '0');

begin

  process (acc_reg, latch_reg, hs, load)
    variable sum : signed(16 downto 0);
  begin
    if load = '1' then
      sum := (others => '0');
    else
      sum := acc_reg;
    end if;
    sum := sum + resize(signed(hs), 17);
    if hs(12) = '1' then
      sum := sum + 1;                           -- ones' complement to two's complement
    end if;
    acc_next <= sum;

    latch_next <= latch_reg;
    if load = '1' then
      latch_next <= acc_reg;
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if ce = '1' then
        acc_reg   <= acc_next;
        latch_reg <= latch_next;
      end if;
    end if;
  end process;

  sample <= latch_reg;

end architecture;
