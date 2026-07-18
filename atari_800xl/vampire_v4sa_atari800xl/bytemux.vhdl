LIBRARY ieee;
USE ieee.std_logic_1164.all; 
use ieee.numeric_std.all;

LIBRARY work;

ENTITY bytemux IS 
	PORT
	(
		DI : IN STD_LOGIC_VECTOR(31 downto 0);
		SEL : IN STD_LOGIC_VECTOR(1 downto 0);
		DO : OUT STD_LOGIC_VECTOR(7 downto 0)
	);
END bytemux;		
		
ARCHITECTURE vhdl OF bytemux IS
BEGIN
	process(DI,SEL)
	begin
		DO <= DI(31 downto 24);
		case SEL is
		when "00" =>
			DO <= DI(7 downto 0);
		when "01" =>
			DO <= DI(15 downto 8);
		when "10" =>
			DO <= DI(23 downto 16);
		when others =>
		end case;
	end process;
	
END vhdl;

