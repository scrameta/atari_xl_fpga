---------------------------------------------------------------------------
-- (c) 2020 mark watson
-- I am happy for anyone to use this for non-commercial use.
-- If my vhdl files are used commercially or otherwise sold,
-- please contact me for explicit permission at scrameta (gmail).
-- This applies for source and binary form and derived works.
---------------------------------------------------------------------------
--
LIBRARY ieee;
USE ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use IEEE.STD_LOGIC_MISC.all;

ENTITY sigmadelta_dither IS
GENERIC (
  LFSR_SEED     : unsigned(15 downto 0) := x"ACE1"
);
PORT 
( 
	CLK : IN STD_LOGIC;
	RESET_N : IN STD_LOGIC;

	ENABLE : IN STD_LOGIC := '1';

        DITHER_OUT1 : OUT STD_LOGIC_VECTOR(15 downto 0);
        DITHER_OUT2 : OUT STD_LOGIC_VECTOR(15 downto 0);
        DITHER_OUT3 : OUT STD_LOGIC_VECTOR(15 downto 0);
        DITHER_OUT4 : OUT STD_LOGIC_VECTOR(15 downto 0)
);
END sigmadelta_dither;

architecture vhdl of sigmadelta_dither is
  signal lfsr_next : unsigned(15 downto 0);
  signal lfsr_reg : unsigned(15 downto 0);
begin

  process(CLK, RESET_N)
  begin
    if RESET_N = '0' then
      lfsr_reg     <= LFSR_SEED;
    elsif rising_edge(CLK) then
      if ENABLE = '1' then
        lfsr_reg <= lfsr_next;
      end if;
    end if;
  end process;

  -- 16-bit Galois LFSR taps: 16,14,13,11
  lfsr_next <= lfsr_reg(14 downto 0) & (lfsr_reg(15) xor lfsr_reg(13) xor lfsr_reg(12) xor lfsr_reg(10));

  DITHER_OUT1 <= std_logic_vector(lfsr_reg);
  DITHER_OUT2 <= std_logic_vector(lfsr_reg(10 downto 0) & lfsr_reg(15 downto 11));
  DITHER_OUT3 <= std_logic_vector(lfsr_reg(5 downto 0)  & lfsr_reg(15 downto 6));
  DITHER_OUT4 <= std_logic_vector(lfsr_reg(12 downto 0) & lfsr_reg(15 downto 13));

end vhdl;

