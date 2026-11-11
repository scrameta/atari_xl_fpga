-------------------------------------------------------------------------------
-- AMY1 sine ROM: sine of a 14-bit phase, a 4-clock pipeline
--
-- Behavioural rewrite of the SINROM schematic block (page 20), see AMY1_SPEC.md 4.5.
--
-- arg(13 downto 0) is a whole cycle: arg(13) the half, arg(12) the quarter. One
-- quarter wave is stored, so
--   a       = arg(11 downto 0), inverted in the even quarters (the table runs
--             backwards there: quarter 0 and 2 mirror quarters 1 and 3)
--   mag     = base(a(11 downto 4)) + interp(slope, a(3 downto 0))   (12 bits)
--   hs      = mag, or not mag in the second half (ones' complement, so a value and
--             its opposite sum to -1, not 0)
-- The base ROM (256 x 17) holds the 12-bit magnitude and a 5-bit slope for each 1/1024
-- cycle; the interpolation ROM (512 x 5) holds slope x fraction.
--
-- Pipeline (one register stage per chip clock, on ce):
--   1  latch arg; fold it: base ROM address
--   2  base ROM data; interpolation ROM address
--   3  interpolation ROM data
--   4  add, sign: hs
-- arg is the phase generator's, valid for the whole clock.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_sine_rom is
  port (
    clk       : in  std_logic;
    ce      : in  std_logic;                      -- chip clock: registers update
    arg       : in  std_logic_vector(13 downto 0);  -- phase (SARG13..8, ARG7..0)
    hs        : out std_logic_vector(12 downto 0);  -- sine, two's complement (ones' complement negation)
    -- ROMs (synchronous read)
    base_addr : out std_logic_vector(7 downto 0);   -- SROMBS: a(11:4)
    base_q    : in  std_logic_vector(16 downto 0);  --   magnitude(11:0) & slope(4:0)
    int_addr  : out std_logic_vector(8 downto 0);   -- SROMINT: slope(4:0) & a(3:0)
    int_q     : in  std_logic_vector(4 downto 0)    --   interpolation
  );
end entity;

architecture rtl of amy1_sine_rom is

  -- stage 1
  signal arg1_reg,  arg1_next  : std_logic_vector(13 downto 0) := (others => '0');
  signal a1   : std_logic_vector(11 downto 0);   -- folded into the first quarter
  signal neg1 : std_logic;
  -- stage 2
  signal frac2_reg, frac2_next : std_logic_vector(3 downto 0) := (others => '0');
  signal mag2_reg,  mag2_next  : unsigned(11 downto 0) := (others => '0');
  signal slope2_reg, slope2_next : std_logic_vector(4 downto 0) := (others => '0');
  signal neg2_reg,  neg2_next  : std_logic := '0';
  -- stage 3
  signal mag3_reg,  mag3_next  : unsigned(11 downto 0) := (others => '0');
  signal int3_reg,  int3_next  : unsigned(4 downto 0) := (others => '0');
  signal neg3_reg,  neg3_next  : std_logic := '0';
  -- stage 4
  signal hs_reg,    hs_next    : std_logic_vector(12 downto 0) := (others => '0');

begin

  -- fold: the even quarters read the table backwards; the sign is half xor quarter
  a1   <= arg1_reg(11 downto 0) when arg1_reg(12) = '1' else not arg1_reg(11 downto 0);
  neg1 <= arg1_reg(13) xor arg1_reg(12);

  base_addr <= a1(11 downto 4);
  int_addr  <= slope2_reg & frac2_reg;

  process (arg, a1, neg1, mag2_reg, neg2_reg,
           mag3_reg, int3_reg, neg3_reg, base_q, int_q)
    variable mag : unsigned(11 downto 0);
  begin
    -- 1: latch the argument
    arg1_next <= arg;

    -- 2: base ROM data
    frac2_next  <= a1(3 downto 0);
    mag2_next   <= unsigned(base_q(16 downto 5));
    slope2_next <= base_q(4 downto 0);
    neg2_next   <= neg1;

    -- 3: interpolation ROM data
    mag3_next <= mag2_reg;
    int3_next <= unsigned(int_q);
    neg3_next <= neg2_reg;

    -- 4: magnitude (wraps at 12 bits) and sign
    mag := mag3_reg + int3_reg;
    if neg3_reg = '1' then
      hs_next <= '1' & std_logic_vector(not mag);
    else
      hs_next <= '0' & std_logic_vector(mag);
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if ce = '1' then
        arg1_reg   <= arg1_next;
        frac2_reg  <= frac2_next;
        mag2_reg   <= mag2_next;
        slope2_reg <= slope2_next;
        neg2_reg   <= neg2_next;
        mag3_reg   <= mag3_next;
        int3_reg   <= int3_next;
        neg3_reg   <= neg3_next;
        hs_reg     <= hs_next;
      end if;
    end if;
  end process;

  hs <= hs_reg;

end architecture;
