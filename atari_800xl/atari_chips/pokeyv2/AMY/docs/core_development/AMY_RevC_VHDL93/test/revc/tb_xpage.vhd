-- Directed test of amy1_engine's XPAGE host path (CONFIG bit 2).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_xpage is end entity;

architecture sim of tb_xpage is
  signal clk : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal done : boolean := false;
  signal cpu_we : std_logic := '0';
  signal cpu_addr : std_logic_vector(2 downto 0) := "000";
  signal cpu_di, cpu_do : std_logic_vector(7 downto 0) := (others => '0');
  signal aux_re, aux_we, aux_rack, aux_wack : std_logic := '0';
  signal aux_raddr, aux_waddr : std_logic_vector(7 downto 0);
  signal aux_rdata, aux_wdata : std_logic_vector(35 downto 0) := (others => '0');
  signal a2_re, a2_we, a2_rack, a2_wack : std_logic := '0';
  signal a2_raddr, a2_waddr : std_logic_vector(6 downto 0);
  signal a2_rdata, a2_wdata : std_logic_vector(35 downto 0) := (others => '0');
  signal push_req, push_ack : std_logic := '0';
  signal push_addr : std_logic_vector(1 downto 0);
  signal push_data : std_logic_vector(7 downto 0);
  signal a2_writes, aux_writes : natural := 0;
  signal last_a2_addr : std_logic_vector(6 downto 0);
  signal last_a2_data : std_logic_vector(35 downto 0);
  signal ack_delay : natural := 0;
begin
  clk <= not clk after 5 ns when not done;

  dut: entity work.amy1_engine port map (
    clk => clk, reset_n => reset_n, tick => '0',
    cpu_we => cpu_we, cpu_addr => cpu_addr, cpu_di => cpu_di, cpu_do => cpu_do,
    aux_re => aux_re, aux_raddr => aux_raddr, aux_rack => aux_rack, aux_rdata => aux_rdata,
    aux_we => aux_we, aux_waddr => aux_waddr, aux_wdata => aux_wdata, aux_wack => aux_wack,
    aux2_re => a2_re, aux2_raddr => a2_raddr, aux2_rack => a2_rack, aux2_rdata => a2_rdata,
    aux2_we => a2_we, aux2_waddr => a2_waddr, aux2_wdata => a2_wdata, aux2_wack => a2_wack,
    push_req => push_req, push_addr => push_addr, push_data => push_data, push_ack => push_ack);

  -- the memory side: aux acks at once; aux2 acks after a few clocks (a busy port)
  aux_wack <= aux_we;
  aux_rack <= aux_re;
  a2_wack <= '1' when a2_we = '1' and ack_delay = 3 else '0';
  mem: process (clk)
  begin
    if rising_edge(clk) then
      if a2_we = '1' then
        if ack_delay = 3 then
          ack_delay <= 0;
          a2_writes <= a2_writes + 1;
          last_a2_addr <= a2_waddr; last_a2_data <= a2_wdata;
        else
          ack_delay <= ack_delay + 1;
        end if;
      end if;
      if aux_we = '1' then aux_writes <= aux_writes + 1; end if;
    end if;
  end process;

  stim: process
    procedure wr(a : natural; d : natural) is
    begin
      wait until rising_edge(clk);
      cpu_addr <= std_logic_vector(to_unsigned(a, 3));
      cpu_di <= std_logic_vector(to_unsigned(d, 8));
      cpu_we <= '1';
      wait until rising_edge(clk);
      cpu_we <= '0';
    end procedure;
    procedure wait_idle is
    begin
      cpu_addr <= "110";
      for i in 1 to 50 loop
        wait until rising_edge(clk);
        wait for 1 ns;
        exit when cpu_do(7) = '0';
      end loop;
      assert cpu_do(7) = '0' report "engine stays busy" severity failure;
    end procedure;
  begin
    wait for 30 ns;
    reset_n <= '1';
    wr(7, 16#04#);                                  -- CONFIG: XPAGE, engine off
    cpu_addr <= "111"; wait until rising_edge(clk); wait for 1 ns;
    assert cpu_do = x"04" report "CONFIG readback" severity failure;
    -- extension word 5 <= $67600000 (the spec's kick header)
    wr(4, 5); wr(0, 16#00#); wr(1, 16#00#); wr(2, 16#60#); wr(5, 16#67#);
    cpu_addr <= "110"; wait for 1 ns;
    assert cpu_do(7) = '1' report "busy while the extension write waits" severity failure;
    wait_idle;
    assert a2_writes = 1 and unsigned(last_a2_addr) = 5 report "aux2 write address" severity failure;
    assert last_a2_data = x"067600000" report "aux2 write data" severity failure;
    assert aux_writes = 0 report "XPAGE write leaked to the base page" severity failure;
    -- ADDR >= 128 is ignored in XPAGE
    wr(4, 200); wr(5, 16#11#);
    wait_idle;
    assert a2_writes = 1 report "ADDR >= 128 must be ignored with XPAGE" severity failure;
    -- XPAGE off: WRITE goes to the base page as before
    wr(7, 16#00#);
    wr(4, 48); wr(0, 16#AA#); wr(5, 16#55#);
    wait_idle;
    assert aux_writes = 1 and a2_writes = 1 report "base-page write" severity failure;
    report "tb_xpage passed";
    done <= true;
    wait;
  end process;
end architecture;
