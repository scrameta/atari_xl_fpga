-------------------------------------------------------------------------------
-- AMY1 exponential ROM: log value to linear, a 5-clock pipeline
--
-- Behavioural rewrite of the XROM schematic block (pages 22-25), see AMY1_SPEC.md 4.3.
--
-- The envelope generator works in log units: frequencies in 1/64 semitone (768 per
-- octave), amplitudes in 1/128 dB. This block turns a 13-bit log value into an
-- 18-bit linear one:
--   log(12 downto 8) + 1 = 3 x octave + third    (the netlist uses a 32-entry ROM,
--                                                 OCTSPL, for this divide by 3)
--   position in the octave = third x 256 + log(7 downto 0)   (0 .. 767)
--   mantissa = base(third, log(7 downto 3)) + interp(slope, log(2 downto 0))
--   xo       = ((2048 + mantissa) x 64) >> (10 - octave)
-- The shift is carried as the netlist's octave code, octave + 5 (5 .. 15). Codes below 5,
-- which only the power-up state has, select no shift: xo holds.
-- The base ROM (128 x 15, 96 words used) holds the 11-bit mantissa and a 4-bit
-- slope for each 1/96 octave; the interpolation ROM (128 x 5) holds slope x fraction.
--
-- Pipeline (one register stage per chip clock, all on tick):
--   1  latch log
--   2  octave / third; base ROM address
--   3  base ROM data; interpolation ROM address
--   4  interpolation ROM data
--   5  add, shift: xo
-- fan rides alongside and comes out as clrdisp 6 clocks later.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_exp_rom is
  port (
    clk       : in  std_logic;
    tick      : in  std_logic;                      -- chip clock: registers update
    log       : in  std_logic_vector(12 downto 0);  -- log value (LOG12..0)
    fan       : in  std_logic;                      -- FAN, delayed to clrdisp
    xo        : out std_logic_vector(17 downto 0);  -- linear value, 5 clocks after log
    clrdisp   : out std_logic;                      -- FAN 6 clocks later (CLRDISP)
    -- ROMs (synchronous read)
    base_addr : out std_logic_vector(6 downto 0);   -- XROMBS: third(1:0) & log(7:3)
    base_q    : in  std_logic_vector(14 downto 0);  --   mantissa(10:0) & slope(3:0)
    int_addr  : out std_logic_vector(6 downto 0);   -- XROMINT: slope(3:0) & log(2:0)
    int_q     : in  std_logic_vector(4 downto 0)    --   interpolation
  );
end entity;

architecture rtl of amy1_exp_rom is

  -- log(12:8) + 1 = 3 x octave + third, as a 32-entry table: octave code (octave + 5) & third.
  -- (A table, as the netlist's OCTSPL ROM: written as / and mod, synthesis builds a divider.)
  type oct3_t is array (0 to 31) of unsigned(5 downto 0);
  function make_oct3 return oct3_t is
    variable t : oct3_t;
  begin
    for i in 0 to 31 loop
      t(i) := to_unsigned((i + 1) / 3 + 5, 4) & to_unsigned((i + 1) mod 3, 2);
    end loop;
    return t;
  end function;
  constant OCT3 : oct3_t := make_oct3;

  -- stage 1
  signal log1_reg,   log1_next   : std_logic_vector(12 downto 0) := (others => '0');
  -- stage 2
  signal code2_reg,  code2_next  : unsigned(3 downto 0) := (others => '0');   -- octave + 5
  signal third_reg,  third_next  : unsigned(1 downto 0) := (others => '0');
  signal pos2_reg,   pos2_next   : std_logic_vector(7 downto 0) := (others => '0');  -- log(7:0)
  -- stage 3
  signal code3_reg,  code3_next  : unsigned(3 downto 0) := (others => '0');
  signal frac3_reg,  frac3_next  : std_logic_vector(2 downto 0) := (others => '0');  -- log(2:0)
  signal man3_reg,   man3_next   : unsigned(10 downto 0) := (others => '0');
  signal slope3_reg, slope3_next : std_logic_vector(3 downto 0) := (others => '0');
  -- stage 4
  signal code4_reg,  code4_next  : unsigned(3 downto 0) := (others => '0');
  signal man4_reg,   man4_next   : unsigned(10 downto 0) := (others => '0');
  signal int4_reg,   int4_next   : unsigned(4 downto 0) := (others => '0');
  -- stage 5
  signal xo_reg,     xo_next     : unsigned(17 downto 0) := (others => '0');
  -- FAN
  signal fan_reg,    fan_next    : std_logic_vector(1 to 6) := (others => '0');

begin

  -- ROM addresses
  base_addr <= std_logic_vector(third_reg) & pos2_reg(7 downto 3);
  int_addr  <= slope3_reg & frac3_reg;

  process (log, fan, log1_reg, code2_reg, pos2_reg, code3_reg, man4_reg, int4_reg,
           code4_reg, xo_reg, fan_reg, base_q, int_q)
    variable man : unsigned(10 downto 0);
  begin
    -- 1: latch
    log1_next <= log;

    -- 2: log(12:8) + 1 = 3 x octave + third
    code2_next  <= OCT3(to_integer(unsigned(log1_reg(12 downto 8))))(5 downto 2);
    third_next  <= OCT3(to_integer(unsigned(log1_reg(12 downto 8))))(1 downto 0);
    pos2_next   <= log1_reg(7 downto 0);

    -- 3: base ROM data
    code3_next  <= code2_reg;
    frac3_next  <= pos2_reg(2 downto 0);
    man3_next   <= unsigned(base_q(14 downto 4));
    slope3_next <= base_q(3 downto 0);

    -- 4: interpolation ROM data
    code4_next  <= code3_reg;
    man4_next   <= man3_reg;
    int4_next   <= unsigned(int_q);

    -- 5: xo = (1.mantissa << 6) >> (15 - code) (the mantissa sum wraps at 11 bits)
    man := man4_reg + int4_reg;
    if code4_reg >= 5 then
      xo_next <= shift_right(unsigned'('1' & man & "000000"), to_integer(15 - code4_reg));
    else
      xo_next <= xo_reg;
    end if;

    fan_next <= fan & fan_reg(1 to 5);
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if tick = '1' then
        log1_reg   <= log1_next;
        code2_reg <= code2_next;
        third_reg  <= third_next;
        pos2_reg   <= pos2_next;
        code3_reg <= code3_next;
        frac3_reg  <= frac3_next;
        man3_reg   <= man3_next;
        slope3_reg <= slope3_next;
        code4_reg <= code4_next;
        man4_reg   <= man4_next;
        int4_reg   <= int4_next;
        xo_reg     <= xo_next;
        fan_reg    <= fan_next;
      end if;
    end if;
  end process;

  xo      <= std_logic_vector(xo_reg);
  clrdisp <= fan_reg(6);

end architecture;
