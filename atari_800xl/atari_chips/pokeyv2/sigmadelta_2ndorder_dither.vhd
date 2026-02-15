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

ENTITY sigmadelta_2ndorder_dither IS
GENERIC (
  DITHER_ENABLE : integer := 1;              -- 0/1
  DITHER_BITS   : integer := 2;              -- 1..4; start small
  LFSR_SEED     : unsigned(15 downto 0) := x"ACE1"
);
PORT 
( 
	CLK : IN STD_LOGIC;
	RESET_N : IN STD_LOGIC;

	ENABLE : IN STD_LOGIC := '1';
	
	AUDIN : IN UNSIGNED(15 downto 0);
	AUDOUT : OUT std_logic
);
END sigmadelta_2ndorder_dither;

architecture vhdl of sigmadelta_2ndorder_dither is
  signal ttl1_reg : signed(21 downto 1) := (others => '0');
  signal ttl2_reg : signed(23 downto 1) := (others => '0');
  signal out_reg  : std_logic := '0';

  signal lfsr : unsigned(15 downto 0) := LFSR_SEED;

  function sat_add(a, b : signed) return signed is
    variable aw  : integer := a'length;
    variable ext : signed(aw downto 0);
    variable r   : signed(aw-1 downto 0);
  begin
    ext := resize(a, aw+1) + resize(b, aw+1);
    if ext(aw) /= ext(aw-1) then
      if ext(aw) = '0' then
        r := (others => '1'); r(aw-1) := '0'; -- +max
      else
        r := (others => '0'); r(aw-1) := '1'; -- -min
      end if;
    else
      r := ext(aw-1 downto 0);
    end if;
    return r;
  end function;

begin

  process(CLK, RESET_N)
    variable audinadj : unsigned(16 downto 0);
    variable fb       : signed(21 downto 0);
    variable ttl1_tmp : signed(21 downto 1);
    variable ttl2_inc : signed(23 downto 1);

    -- threshold dither (TPDF-ish): (u1 - u2)
    variable u1, u2   : signed(DITHER_BITS downto 0);
    variable dith23   : signed(23 downto 1);

    variable q_in     : signed(23 downto 1);
    variable out_next : std_logic;
  begin
    if RESET_N = '0' then
      ttl1_reg <= (others => '0');
      ttl2_reg <= (others => '0');
      out_reg  <= '0';
      lfsr     <= LFSR_SEED;
    elsif rising_edge(CLK) then
      if ENABLE = '1' then

        -- 16-bit Galois LFSR taps: 16,14,13,11
        lfsr <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));

        -- Keep your original input shaping
        audinadj := resize(AUDIN, 17) + to_unsigned(4096, 17) - resize(AUDIN(15 downto 3), 17);

        -- Build tiny threshold dither (default ~±1..3 LSB at the *threshold* domain)
        if DITHER_ENABLE = 1 then
          u1 := resize(signed('0' & lfsr(DITHER_BITS-1 downto 0)), DITHER_BITS+1)
                - to_signed(2**(DITHER_BITS-1), DITHER_BITS+1);
          u2 := resize(signed('0' & lfsr(2*DITHER_BITS-1 downto DITHER_BITS)), DITHER_BITS+1)
                - to_signed(2**(DITHER_BITS-1), DITHER_BITS+1);
          dith23 := resize(resize(u1 - u2, 23), 23);
        else
          dith23 := (others => '0');
        end if;

        -- Quantizer: use full-precision sign, with dither to kill limit cycles
        q_in := sat_add(ttl2_reg, dith23);
        if q_in(q_in'left) = '0' then
          out_next := '1';
        else
          out_next := '0';
        end if;

        -- Feedback (same style as your original: unipolar bit at 2^16)
        fb := (others => '0');
        fb(16) := out_next;

        -- Saturating integrators
        ttl1_tmp := sat_add(ttl1_reg, resize(signed("0" & audinadj), 21) - resize(fb(20 downto 0), 21));
        ttl2_inc := resize(
                      (ttl1_tmp(20 downto 1) & '0') -
                      (resize(fb(20 downto 0), 22) + resize(fb(18 downto 0) & "00", 22)),
                      23
                    );

        ttl1_reg <= ttl1_tmp;
        ttl2_reg <= sat_add(ttl2_reg, ttl2_inc);
        out_reg  <= out_next;

      end if;
    end if;
  end process;

  AUDOUT <= out_reg;

end vhdl;

