-------------------------------------------------------------------------------
-- Testbench for the phase-B amy1 (clk, ce, register port): replays a schedule of host
-- accesses at given chip clocks and logs, per chip clock, the samples, the host reads and
-- every RAM write, in the same format as tb_amy1_log for phase A.
--
-- Schedule (<SCHED>_replay.txt, from tb_amy1_log's logs by mkreplay.py):
--   r R       reset is released so that the core's reset ends in clock r
--   n W r d   write register r = d in clock n (a command: two clocks before its busy)
--   n D r 0   read register r in clock n
-- CE_SPACING clks per chip clock (>= 2); writes go in the first clks of the chip clock.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_amy1b is
  generic (
    SCHED      : string  := "pa";       -- schedule prefix
    LOG_PREFIX : string  := "pb";       -- logs: <prefix>_mem.txt, _samp.txt, _rd.txt
    NCLK       : natural := 27000;      -- chip clocks to run
    CE_SPACING : natural := 4;
    MEM_FILE   : string  := "amy1_mem.hex";   -- the logical-address image
    NOISE_FIX  : boolean := true;
    MEM_PACKED : boolean := true
  );
end entity;

architecture sim of tb_amy1b is
  signal clk, ce, reset : std_logic := '0';
  signal addr : std_logic_vector(1 downto 0) := "00";
  signal we : std_logic := '0';
  signal wdata, rdata : std_logic_vector(7 downto 0);
  signal rdy, sample_stb, sample_v0 : std_logic;
  signal sample : signed(16 downto 0);
  signal load_we : std_logic := '0';
  signal load_addr : std_logic_vector(10 downto 0) := (others => '0');
  signal load_data : std_logic_vector(31 downto 0) := (others => '0');
  signal clockn : natural := 1;          -- the chip clock in progress

  type act_kind is (A_WRITE, A_READ);
  type act_t is record
    clock : natural;
    kind  : act_kind;
    reg   : natural;
    data  : natural;
  end record;
  type act_array is array (natural range <>) of act_t;
  constant MAXACT : natural := 4096;
begin

  dut: entity work.amy1 generic map (NOISE_FIX => NOISE_FIX, MEM_PACKED => MEM_PACKED) port map (
    clk => clk, ce => ce, reset => reset, ext_ack => open,
    addr => addr, we => we, wdata => wdata, rdata => rdata, rdy => rdy,
    sample => sample, sample_stb => sample_stb, sample_v0 => sample_v0,
    load_we => load_we, load_addr => load_addr, load_data => load_data);

  run: process
    file fs : text;
    file fm : text open read_mode is MEM_FILE;
    file fr : text open write_mode is LOG_PREFIX & "_rd.txt";
    variable l : line;
    variable c : character;
    variable n, r, d, rclk : natural;
    variable acts : act_array(0 to MAXACT - 1);
    variable na : natural := 0;
    variable w : std_logic_vector(31 downto 0);
    variable cnt : natural := 0;
    variable ai : natural := 0;

    procedure clock_edge is
    begin
      wait for 5 ns; clk <= '1';
      wait for 5 ns; clk <= '0';
    end procedure;

  begin
    -- the replay schedule (mkreplay.py): 'r R', then 'n W reg data' / 'n D reg 0'
    file_open(fs, SCHED & "_replay.txt", read_mode);
    readline(fs, l); read(l, rclk);
    while not endfile(fs) loop
      readline(fs, l); read(l, n); read(l, c); read(l, c); read(l, r); read(l, d);
      if c = 'W' then acts(na) := (n, A_WRITE, r, d); else acts(na) := (n, A_READ, r, 0); end if;
      na := na + 1;
    end loop;
    file_close(fs);

    -- fill the memories
    reset <= '1';
    while not endfile(fm) loop
      readline(fm, l); hread(l, w);
      load_we <= '1'; load_addr <= std_logic_vector(to_unsigned(cnt, 11)); load_data <= w;
      clock_edge;
      cnt := cnt + 1;
    end loop;
    load_we <= '0';

    -- run, one chip clock at a time
    for clk_i in 1 to NCLK loop
      clockn <= clk_i;
      if clk_i = rclk - 1 then reset <= '0'; end if;
      for cyc in 0 to CE_SPACING - 1 loop
        we <= '0';
        -- this chip clock's accesses, in schedule order (writes in the first clks)
        if cyc < CE_SPACING - 1 and ai < na and acts(ai).clock = clk_i then
          addr <= std_logic_vector(to_unsigned(acts(ai).reg, 2));
          if acts(ai).kind = A_WRITE then
            we <= '1'; wdata <= std_logic_vector(to_unsigned(acts(ai).data, 8));
          else
            wait for 1 ns;
            write(l, clk_i); write(l, string'(" ")); write(l, acts(ai).reg); write(l, string'(" "));
            write(l, to_hstring(rdata)); writeline(fr, l);
          end if;
          ai := ai + 1;
        elsif ai < na and acts(ai).clock < clk_i then
          report "schedule entry for clock " & integer'image(acts(ai).clock) & " missed" severity failure;
        end if;
        if cyc = CE_SPACING - 1 then ce <= '1'; else ce <= '0'; end if;
        clock_edge;
      end loop;
      ce <= '0';
    end loop;
    report "done" severity note;
    std.env.finish;
  end process;

  -- per chip clock logs (taken at the ce that ends the clock)
  clog: block
    alias h_we  is <<signal .tb_amy1b.dut.harmcurntval_we    : std_logic>>;
    alias h_a   is <<signal .tb_amy1b.dut.harm_addr          : std_logic_vector(5 downto 0)>>;
    alias h_d   is <<signal .tb_amy1b.dut.harmcurntval_wdata : std_logic_vector(12 downto 0)>>;
    alias b_we  is <<signal .tb_amy1b.dut.harmbrkpoint_we    : std_logic>>;
    alias b_d   is <<signal .tb_amy1b.dut.harmbrkpoint_wdata : std_logic_vector(15 downto 0)>>;
    alias l_we  is <<signal .tb_amy1b.dut.lhpram_we          : std_logic>>;
    alias l_d   is <<signal .tb_amy1b.dut.lhpram_wdata       : std_logic_vector(0 downto 0)>>;
    alias v_we  is <<signal .tb_amy1b.dut.voice18_we         : std_logic>>;
    alias v_a   is <<signal .tb_amy1b.dut.voice_addr         : std_logic_vector(3 downto 0)>>;
    alias v_d   is <<signal .tb_amy1b.dut.voice18_wdata      : std_logic_vector(17 downto 0)>>;
    alias w_we  is <<signal .tb_amy1b.dut.voice3_we          : std_logic>>;
    alias w_d   is <<signal .tb_amy1b.dut.voice3_wdata       : std_logic_vector(2 downto 0)>>;
    alias n_we  is <<signal .tb_amy1b.dut.noise_we           : std_logic>>;
    alias n_a   is <<signal .tb_amy1b.dut.noise_addr         : std_logic_vector(5 downto 0)>>;
    alias n_d   is <<signal .tb_amy1b.dut.noise_wdata        : std_logic_vector(2 downto 0)>>;
    alias p_we  is <<signal .tb_amy1b.dut.phaseram_we        : std_logic>>;
    alias p_a   is <<signal .tb_amy1b.dut.phaseram_addr      : std_logic_vector(2 downto 0)>>;
    alias p_d   is <<signal .tb_amy1b.dut.phaseram_wdata     : std_logic_vector(19 downto 0)>>;
  begin
    process (clk)
      file fm : text open write_mode is LOG_PREFIX & "_mem.txt";
      file fp : text open write_mode is LOG_PREFIX & "_samp.txt";
      variable l : line;
      variable lat : std_logic_vector(16 downto 0);
      procedure put(name : string; a, d : std_logic_vector) is
      begin
        write(l, clockn); write(l, string'(" ") & name & " ");
        write(l, to_hstring(a)); write(l, string'(" ")); write(l, to_hstring(d));
        writeline(fm, l);
      end procedure;
    begin
      if rising_edge(clk) and ce = '1' then
        -- (harmonic and voice addresses in the netlist's order, as phase A logs them)
        if h_we = '1' then put("hcv", not h_a, h_d); end if;
        if b_we = '1' then put("hbp", not h_a, b_d); end if;
        if l_we = '1' then put("lhp", not h_a, l_d); end if;
        if v_we = '1' then put("v18", not v_a, v_d); end if;
        if w_we = '1' then put("v3 ", not v_a, w_d); end if;
        if n_we = '1' then put("nz ", n_a, n_d); end if;
        if p_we = '1' then put("ph ", p_a, p_d); end if;
        if sample_stb = '1' then
          lat := std_logic_vector(sample);
          lat(16) := not lat(16); lat(15) := not lat(15);   -- the chip's offset-binary latch
          write(l, clockn); write(l, string'(" ")); write(l, to_hstring(lat));
          write(l, string'(" ")); write(l, std_logic'image(sample_v0)(2)); writeline(fp, l);
        end if;
      end if;
    end process;
  end block;

end architecture;
