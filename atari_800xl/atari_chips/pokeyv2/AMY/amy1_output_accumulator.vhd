-------------------------------------------------------------------------------
-- AMY1 output accumulator: sums the sine values into samples, drives SAMP
--
-- Behavioural rewrite of the ACC schematic block (page 1), see AMY1_SPEC.md 4.6.
--
-- Every chip clock it adds one sine value: acc = acc + hs. hs is in ones' complement
-- form for negative values (sine_rom), so a carry-in of 1 is added when hs is negative,
-- making the sum exact two's complement. On load (LDSAMP) the accumulator's total is
-- latched as the sample and the sum restarts from this clock's hs.
--
-- The sample latch is offset binary: bits 16 and 15 are inverted, so silence is
-- $8000 on SAMP15..0. SAMP0 is shared: it carries bit 16 instead of bit 0 while OUTSTB
-- is active and through the following CLKN (and never in test mode).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_output_accumulator is
  port (
    clk        : in  std_logic;
    tick       : in  std_logic;                      -- chip clock: registers update
    sample     : in  std_logic;                      -- end of CLKN
    clkn_ph    : in  std_logic;                      -- chip CLKN phase (OUTSTB latch)
    hs         : in  std_logic_vector(12 downto 0);  -- sine value (sine_rom)
    load       : in  std_logic;                      -- latch the sample, restart the sum
    test       : in  std_logic;                      -- test mode: load every clock, SAMP0 = bit 0
    outstb     : in  std_logic;                      -- output strobe (OUTSTB, active high)
    samp_oe    : in  std_logic;                      -- drive SAMP15..0 (the OE pin, active high)
    ld_samp    : out std_logic;                      -- the latch is loading (LDSAMP)
    samp_latch : out std_logic_vector(16 downto 0);  -- the sample, offset binary
    samp_pin   : out std_logic_vector(15 downto 0)   -- SAMP15..0 pins
  );
end entity;

architecture rtl of amy1_output_accumulator is

  signal acc_reg,   acc_next   : signed(16 downto 0) := (others => '0');
  signal latch_reg, latch_next : signed(16 downto 0) := (others => '0');  -- accumulator total
  signal pin_reg,   pin_next   : std_logic_vector(15 downto 0) := (others => '0');  -- held pins
  signal stb_reg               : std_logic := '1';   -- OUTSTB at the last CLKN (netlist power-up: active)

  signal ld     : std_logic;
  signal lat    : std_logic_vector(16 downto 0);
  signal stb_l  : std_logic;
  signal sel16  : std_logic;
  signal pins   : std_logic_vector(15 downto 0);

begin

  ld <= load or test;

  process (acc_reg, latch_reg, pin_reg, hs, ld, pins, samp_oe)
    variable sum : signed(16 downto 0);
  begin
    if ld = '1' then
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
    if ld = '1' then
      latch_next <= acc_reg;
    end if;

    -- pins: driven while enabled, otherwise they keep their last value
    pin_next <= pin_reg;
    if samp_oe = '1' then
      pin_next <= pins;
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if sample = '1' then
        stb_reg <= outstb;
      end if;
      if tick = '1' then
        acc_reg   <= acc_next;
        latch_reg <= latch_next;
        pin_reg   <= pin_next;
      end if;
    end if;
  end process;

  -- offset binary: bits 16 and 15 inverted
  lat <= not std_logic(latch_reg(16)) & not std_logic(latch_reg(15)) &
         std_logic_vector(latch_reg(14 downto 0));

  -- SAMP0 carries bit 16 while OUTSTB is active and through the following CLKN
  stb_l <= outstb when clkn_ph = '1' else stb_reg;
  sel16 <= not test and (outstb or stb_l);
  pins  <= lat(15 downto 1) & lat(16) when sel16 = '1' else lat(15 downto 0);

  ld_samp    <= ld;
  samp_latch <= lat;
  samp_pin   <= pins when samp_oe = '1' else pin_reg;

end architecture;
