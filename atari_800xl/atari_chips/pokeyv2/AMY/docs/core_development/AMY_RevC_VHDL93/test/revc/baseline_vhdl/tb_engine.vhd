-------------------------------------------------------------------------------
-- amy1_engine on its own, time scaled down 32x (a tick every clock):
--   host:   "clocks reg value" per line: wait that many clocks, then write
--           register 8+reg (EVENT writes wait while the queue is full)
--   RAM:    the aux port of a 256 x 36 RAM; reads are refused on "step" clocks
--           (375 of every 896, never two in a row) and writes on random clocks
--   FIFO:   4 entries, an A/B/C write leaves after 5 clocks, a command after 14
-- Logs every push ("reg value") and, per event, the engine's time when it read
-- the voice state.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.math_real.all;

entity tb_engine is
  generic (
    CMD_FILE  : string := "eng_cmds.txt";
    OUT_FILE  : string := "eng_out.txt";
    NOW_FILE  : string := "eng_now.txt"
  );
end entity;

architecture sim of tb_engine is
  signal clk : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal cpu_we : std_logic := '0';
  signal cpu_addr : std_logic_vector(2 downto 0) := "000";
  signal cpu_di, cpu_do : std_logic_vector(7 downto 0) := (others => '0');
  signal aux_re, aux_rack, aux_we, aux_wack : std_logic;
  signal aux_raddr, aux_waddr : std_logic_vector(7 downto 0);
  signal aux_rdata, aux_wdata : std_logic_vector(35 downto 0) := (others => '0');
  signal push_req, push_ack : std_logic := '0';
  signal push_addr : std_logic_vector(1 downto 0);
  signal push_data : std_logic_vector(7 downto 0);
  signal step, wblock : std_logic := '0';
  signal fifo_n : natural := 0;
  signal done : boolean := false;

  type ram_t is array (0 to 255) of std_logic_vector(35 downto 0);
  signal ram : ram_t := (others => (others => '0'));
begin
  clk <= not clk after 5 ns when not done;

  dut: entity work.amy1_engine port map (
    clk => clk, reset_n => reset_n, tick => '1',
    cpu_we => cpu_we, cpu_addr => cpu_addr, cpu_di => cpu_di, cpu_do => cpu_do,
    aux_re => aux_re, aux_raddr => aux_raddr, aux_rack => aux_rack, aux_rdata => aux_rdata,
    aux_we => aux_we, aux_waddr => aux_waddr, aux_wdata => aux_wdata, aux_wack => aux_wack,
    push_req => push_req, push_addr => push_addr, push_data => push_data, push_ack => push_ack);

  -- the RAM and its port rules
  aux_rack <= aux_re and not step;
  aux_wack <= aux_we and not wblock;
  ram_p: process (clk)
    variable acc : natural := 0;
    variable s1 : positive := 5;
    variable s2 : positive := 9;
    variable r : real;
  begin
    if rising_edge(clk) then
      if aux_rack = '1' then
        aux_rdata <= ram(to_integer(unsigned(aux_raddr)));
      end if;
      if aux_wack = '1' then
        ram(to_integer(unsigned(aux_waddr))) <= aux_wdata;
      end if;
      -- next clock: a step? (375/896, never two in a row)
      if step = '1' then
        step <= '0';
      else
        acc := acc + 375;
        if acc >= 896 then acc := acc - 896; step <= '1'; else step <= '0'; end if;
      end if;
      uniform(s1, s2, r);
      if r < 0.3 then wblock <= '1'; else wblock <= '0'; end if;
    end if;
  end process;

  -- the command FIFO and its log
  fifo_p: process (clk)
    file fo : text open write_mode is OUT_FILE;
    variable l : line;
    type q_t is array (0 to 3) of std_logic_vector(1 downto 0);
    variable q : q_t;
    variable n, head, wait_c : natural := 0;
  begin
    if rising_edge(clk) then
      if wait_c > 0 then
        wait_c := wait_c - 1;
      elsif n > 0 then
        if q(head) = "00" then wait_c := 13; else wait_c := 4; end if;
        head := (head + 1) mod 4;
        n := n - 1;
      end if;
      if push_req = '1' and push_ack = '1' then
        q((head + n) mod 4) := push_addr;
        n := n + 1;
        write(l, to_integer(unsigned(push_addr))); write(l, string'(" "));
        write(l, to_integer(unsigned(push_data))); writeline(fo, l);
      end if;
      fifo_n <= n;
    end if;
  end process;
  push_ack <= push_req when fifo_n < 4 else '0';

  -- the engine's time when it reads a voice state (age) and writes one (release time)
  now_p: process (clk)
    file fn : text open write_mode is NOW_FILE;
    variable l : line;
    variable vs_read : boolean := false;
    alias now is << signal .tb_engine.dut.now_reg : unsigned(7 downto 0) >>;
    alias pw is << signal .tb_engine.dut.pw_reg : std_logic >>;
  begin
    if rising_edge(clk) then
      if vs_read then
        write(l, string'("r ")); write(l, to_integer(now)); writeline(fn, l);
      end if;
      vs_read := aux_rack = '1' and aux_raddr(7 downto 3) = "00100";
      if aux_wack = '1' and aux_waddr(7 downto 3) = "00100" and pw = '0' then
        write(l, string'("w ")); write(l, to_integer(now)); writeline(fn, l);
      end if;
    end if;
  end process;

  host: process
    file fc : text open read_mode is CMD_FILE;
    variable l : line;
    variable dly, reg, val : integer;
  begin
    wait for 20 ns;
    reset_n <= '1';
    while not endfile(fc) loop
      readline(fc, l);
      next when l'length = 0;
      read(l, dly); read(l, reg); read(l, val);
      for i in 1 to dly loop wait until rising_edge(clk); end loop;
      if reg = 3 then                          -- EVENT: wait while the queue is full
        loop
          cpu_addr <= "110";
          wait for 1 ns;
          exit when cpu_do(6) = '0';
          wait until rising_edge(clk);
        end loop;
      end if;
      wait until falling_edge(clk);
      cpu_addr <= std_logic_vector(to_unsigned(reg, 3));
      cpu_di <= std_logic_vector(to_unsigned(val, 8));
      cpu_we <= '1';
      wait until falling_edge(clk);
      cpu_we <= '0';
    end loop;
    -- wait until the engine has finished, and the FIFO is empty
    loop
      wait until rising_edge(clk);
      cpu_addr <= "110";
      wait for 1 ns;
      exit when cpu_do(7) = '0' and fifo_n = 0;
    end loop;
    report "done";
    done <= true;
    wait;
  end process;
end architecture;
