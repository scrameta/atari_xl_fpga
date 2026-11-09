-------------------------------------------------------------------------------
-- AMY Rev C: persistent per-harmonic phase offset increment.
-- detune: signed Q0.6 harmonic offset, stochasticity: unsigned 6-bit amplitude.
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
    new_phase : out std_logic_vector(17 downto 0)
  );
end entity;
architecture rtl of amy1_ext_phase is
begin
  process(freq_inc, detune, stochasticity, random_byte, old_phase, ext_enable)
    variable dt : signed(24 downto 0);
    variable nz : signed(14 downto 0);
    variable accum : signed(17 downto 0);
  begin
    dt := signed(detune) * signed('0' & freq_inc);
    nz := signed(random_byte) * signed('0' & stochasticity);
    accum := signed(old_phase);
    if ext_enable = '1' then
      -- 20-bit fundamental phase -> 18-bit offset, coefficient /64: >> 8.
      accum := accum + resize(shift_right(dt, 8), 18) + resize(nz, 18);
    end if;
    new_phase <= std_logic_vector(accum);
  end process;
end architecture;
