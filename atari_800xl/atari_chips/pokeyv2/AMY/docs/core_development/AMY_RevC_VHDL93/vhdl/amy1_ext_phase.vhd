-------------------------------------------------------------------------------
-- AMY Rev C: persistent per-harmonic phase offset increment.
-- detune: signed Q0.6 harmonic offset.
-- white: voice type 3 (extensions unlocked): the offset takes a full-circle
--   random step every sample, so the harmonic's phase is uniformly random and
--   it sounds as white noise at its envelope level (A * cos(random)), with no
--   residual tone.  Detune and diffusion are then irrelevant.
-- stochasticity s = eee mmm: exponential random-walk step
--   step = random_byte * (8 + mmm) << eee,   s = 0 -> no diffusion
-- Line width (half width) ~0.6 Hz at s=1, x4 per +8, ~33 Hz at 24, ~530 Hz at
-- 40, ~2 kHz at 48; from about 56 the phase is effectively re-randomised each
-- sample, so the harmonic becomes white noise that follows its envelope.
-- Independent of frequency.  Modulo-2^18 wrap of the shifted step is intended.
-- 18-bit accumulator: 2^18 units = one full cycle. Modulo arithmetic is intended.
-- Uses the voice's *frequency increment*, not its wrapped phase; coefficient
-- changes do not cause discontinuous jumps in the accumulated partial phase.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity amy1_ext_phase is
  port (
    freq_inc : in std_logic_vector(17 downto 0);
    detune : in std_logic_vector(5 downto 0);
    stochasticity : in std_logic_vector(5 downto 0);
    random_byte : in std_logic_vector(7 downto 0);
    old_phase : in std_logic_vector(17 downto 0);
    ext_enable : in std_logic;
    white : in std_logic := '0';
    new_phase : out std_logic_vector(17 downto 0)
  );
end entity;
architecture rtl of amy1_ext_phase is
begin
  process(freq_inc, detune, stochasticity, random_byte, old_phase, ext_enable, white)
    variable dt : signed(24 downto 0);
    variable nm : signed(12 downto 0);
    variable nz : signed(17 downto 0);
    variable accum : signed(17 downto 0);
  begin
    dt := signed(detune) * signed('0' & freq_inc);
    nm := signed(random_byte) * signed("01" & stochasticity(2 downto 0));
    nz := shift_left(resize(nm, 18), to_integer(unsigned(stochasticity(5 downto 3))));
    if stochasticity = "000000" then
      nz := (others => '0');
    end if;
    accum := signed(old_phase);
    if ext_enable = '1' then
      -- 20-bit fundamental phase -> 18-bit offset, coefficient /64: >> 8.
      if white = '1' then
        accum := accum + signed(random_byte & "0000000000");
      else
        accum := accum + resize(shift_right(dt, 8), 18) + nz;
      end if;
    end if;
    new_phase <= std_logic_vector(accum);
  end process;
end architecture;
