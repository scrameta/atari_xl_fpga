---------------------------------------------------------------------------
-- True dual-port RAM for the AMY ROM pairs, behavioural model for simulation
-- (same ports and behaviour as amy1_dpram_altera.vhd, which Quartus uses).
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_dpram is
  generic (
    AW : natural;
    DW : natural
  );
  port (
    clk    : in  std_logic;
    en     : in  std_logic;
    we_a   : in  std_logic;
    addr_a : in  std_logic_vector(AW - 1 downto 0);
    data_a : in  std_logic_vector(DW - 1 downto 0);
    q_a    : out std_logic_vector(DW - 1 downto 0);
    addr_b : in  std_logic_vector(AW - 1 downto 0);
    q_b    : out std_logic_vector(DW - 1 downto 0)
  );
end entity;

architecture sim of amy1_dpram is
  type ram_t is array (0 to 2 ** AW - 1) of std_logic_vector(DW - 1 downto 0);
  signal ram : ram_t;
  signal qa, qb : std_logic_vector(DW - 1 downto 0) := (others => '0');
begin
  -- M9K behaviour: a read happens at the clock edge and the output holds it
  -- until the next enabled edge. Port A shows the new data on a write; port B
  -- shows the OLD data when port A writes the same word at the same edge.
  process (clk)
  begin
    if rising_edge(clk) then
      if en = '1' then
        if we_a = '1' then
          ram(to_integer(unsigned(addr_a))) <= data_a;
          qa <= data_a;
        else
          qa <= ram(to_integer(unsigned(addr_a)));
        end if;
        qb <= ram(to_integer(unsigned(addr_b)));
      end if;
    end if;
  end process;
  q_a <= qa;
  q_b <= qb;
end architecture;
