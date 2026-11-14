---------------------------------------------------------------------------
-- (c) 2013 mark watson
-- I am happy for anyone to use this for non-commercial use.
-- If my vhdl files are used commercially or otherwise sold,
-- please contact me for explicit permission at scrameta (gmail).
-- This applies for source and binary form and derived works.
---------------------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.all;
use ieee.numeric_std.all;

ENTITY pokey_poly_4 IS
PORT 
( 
	CLK : IN STD_LOGIC;
	RESET_N : IN STD_LOGIC;
	ENABLE : IN STD_LOGIC;
	INIT : IN STD_LOGIC;	
	
	BIT_OUT : OUT STD_LOGIC
);
END pokey_poly_4;

ARCHITECTURE vhdl OF pokey_poly_4 IS
	signal shift_reg: std_logic_vector(3 downto 0);
	signal shift_next: std_logic_vector(3 downto 0);
BEGIN
	-- register
	process(clk, reset_n)
	begin
		if (reset_n = '0') then
			shift_reg <= "1010";
		elsif (clk'event and clk='1') then
			shift_reg <= shift_next;
		end if;
	end process;
	
	-- next state
	process(shift_reg,enable,init)
	begin
		shift_next <= shift_reg;
		if (enable = '1') then
			shift_next <= ((shift_reg(1) xnor shift_reg(0)) and not(init))&shift_reg(3 downto 1);
		end if;
	end process;
	
	-- output
	-- The channel noise latches are transparent while the timer pulse is active,
	-- so they see the poly4 bit of the current cycle, i.e. the value shift_reg(0)
	-- takes this cycle (= shift_reg(1) when shifting). Matches the measured
	-- sampling points in P. Rosowski, "The C distortion in POKEY sound generator"
	-- (tables 15/16: after init exit at cycle 0, ch1 sees E(n) at cycle n, so a
	-- 64KHz sample at cycle 25 takes E10 and a 15KHz sample at cycle 84 takes E9).
	bit_out <= shift_reg(1) when enable = '1' else shift_reg(0);
		
END vhdl;
