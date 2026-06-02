LIBRARY ieee;
USE ieee.std_logic_1164.all; 
use ieee.numeric_std.all;

entity pll_reset_sync is
    generic (
        RESET_CYCLES : natural := 64   -- adjust per design
    );
    port (
        clk        : in  std_logic;
        pll_locked : in  std_logic;
        reset_n    : out std_logic
    );
end entity;

architecture rtl of pll_reset_sync is
    signal locked_sync : std_logic_vector(1 downto 0) := (others => '0');
    signal cnt : unsigned(5 downto 0) := (others => '0');  -- counts 0..63
begin
    -- sync
    process(clk)
    begin
        if rising_edge(clk) then
            locked_sync(0) <= pll_locked;
            locked_sync(1) <= locked_sync(0);
        end if;
    end process;

    -- stretch
    process(clk)
    begin
        if rising_edge(clk) then
            if locked_sync(1) = '0' then
                cnt <= (others => '0');
            elsif cnt /= RESET_CYCLES-1 then
                cnt <= cnt + 1;
            end if;
        end if;
    end process;

    reset_n <= '1' when cnt = RESET_CYCLES-1 else '0';
end architecture;

