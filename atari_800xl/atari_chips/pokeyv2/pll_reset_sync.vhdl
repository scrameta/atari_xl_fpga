LIBRARY ieee;
USE ieee.std_logic_1164.all; 

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
    signal shreg       : std_logic_vector(RESET_CYCLES-1 downto 0) := (others => '0');
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
                shreg <= (others => '0');
            else
                shreg <= shreg(RESET_CYCLES-2 downto 0) & '1';
            end if;
        end if;
    end process;

    reset_n <= shreg(RESET_CYCLES-1);
end architecture;

