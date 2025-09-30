LIBRARY ieee;
USE ieee.std_logic_1164.all; 
use ieee.numeric_std.all;

LIBRARY work;

ENTITY bytesel IS 
	PORT
	(
		DI : IN STD_LOGIC_VECTOR(31 downto 0);
		SEL : IN STD_LOGIC_VECTOR(7 downto 0);
		DO : OUT STD_LOGIC_VECTOR(31 downto 0)
	);
END bytesel;		
		
ARCHITECTURE vhdl OF bytesel IS
BEGIN
	bytemux0 : entity work.bytemux
	port map(
		di => DI,
		sel => sel(1 downto 0),
		do => DO(7 downto 0)
	);
	bytemux1 : entity work.bytemux
	port map(
		di => DI,
		sel => sel(3 downto 2),
		do => DO(15 downto 8)
	);
	bytemux2 : entity work.bytemux
	port map(
		di => DI,
		sel => sel(5 downto 4),
		do => DO(23 downto 16)
	);
	bytemux3 : entity work.bytemux
	port map(
		di => DI,
		sel => sel(7 downto 6),
		do => DO(31 downto 24)
	);
END vhdl;

