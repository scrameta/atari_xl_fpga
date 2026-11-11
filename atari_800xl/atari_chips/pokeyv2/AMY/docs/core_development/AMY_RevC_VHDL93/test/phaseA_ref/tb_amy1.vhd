-------------------------------------------------------------------------------
-- Testbench: replays host writes ("time addr data" per line, time in 5 ns units)
-- exactly like the Verilator harness (vlat/main.cpp), waiting for INT/RDY before
-- each write, and logs the SAMP pins on every OUTSTB edge.
-- One step = 8 time units. IDLE_NUM/IDLE_DEN insert idle clocks (step_en = 0)
-- between steps with a fractional accumulator, to check the clock enable.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_amy1 is
  generic (
    CMD_FILE : string  := "cmds.txt";
    OUT_FILE : string  := "samples.txt";
    STOP     : natural := 1300000;
    STEP_NUM : natural := 1;            -- step_en rate = STEP_NUM / STEP_DEN of clk
    STEP_DEN : natural := 2;            -- (never two steps on consecutive clocks)
    MEM_FILE : string  := "amy1_mem.hex";
    NOISE_FIX : boolean := true;
    READ_FILE  : string := "";          -- log host reads (command addr 4..7 = read register 0..3)
    TRACE_FILE : string := ""           -- log every RAM write: step, RAM, address, data
  );
end entity;

architecture sim of tb_amy1 is
  signal clk, step_en : std_logic := '0';
  signal resetn, csn, wrn, rdn : std_logic := '1';
  signal db_out : std_logic_vector(7 downto 0);
  signal stepn : natural := 0;
  signal a : std_logic_vector(1 downto 0) := "00";
  signal db_in : std_logic_vector(7 downto 0) := (others => '0');
  signal db_drive : std_logic := '0';
  signal intrdy, outstbn : std_logic;
  signal samp : std_logic_vector(15 downto 0);
  signal samp_latch : std_logic_vector(16 downto 0);
  signal load_we : std_logic := '0';
  signal load_addr : std_logic_vector(10 downto 0) := (others => '0');
  signal load_data : std_logic_vector(31 downto 0) := (others => '0');
begin

  dut: entity work.amy1 generic map (NOISE_FIX => NOISE_FIX) port map (
    clk => clk, step_en => step_en,
    pin_resetn => resetn, pin_test => '0', pin_oen => '0',
    pin_csn => csn, pin_wrn => wrn, pin_rdn => rdn, pin_a => a,
    pin_db_in => db_in, pin_db_drive => db_drive,
    pin_db_out => db_out, pin_db_oe => open,
    pin_intrdy => intrdy, pin_samp => samp, pin_outstbn => outstbn,
    pin_v0 => open, samp_latch => samp_latch, samp_load => open,
    load_we => load_we, load_addr => load_addr, load_data => load_data);

  run: process
    file fc : text open read_mode is CMD_FILE;
    file fo : text open write_mode is OUT_FILE;
    variable l : line;
    variable t_cmd, a_cmd, d_cmd : integer;
    variable have_cmd : boolean := false;
    variable phase : integer := 0;
    variable t_wr, now_u : integer := 0;
    variable last_strobe : std_logic := 'U';
    variable acc : natural := 0;
    file fr : text;
    variable rd_cycle : boolean := false;

    procedure next_cmd is
    begin
      have_cmd := false;
      while not endfile(fc) loop
        readline(fc, l);
        if l'length > 0 then
          read(l, t_cmd); read(l, a_cmd); read(l, d_cmd);
          have_cmd := true;
          exit;
        end if;
      end loop;
    end procedure;

    procedure tick(en : std_logic) is
    begin
      step_en <= en;
      wait for 1 ns;  clk <= '1';
      wait for 5 ns;  clk <= '0';
      wait for 4 ns;
    end procedure;
    file fm : text open read_mode is MEM_FILE;
    variable w : std_logic_vector(31 downto 0);
    variable n : natural := 0;
  begin
    if READ_FILE /= "" then file_open(fr, READ_FILE, write_mode); end if;
    resetn <= '0';
    -- fill the memories from the image
    while not endfile(fm) loop
      readline(fm, l); hread(l, w);
      load_we <= '1'; load_addr <= std_logic_vector(to_unsigned(n, 11)); load_data <= w;
      tick('0');
      n := n + 1;
    end loop;
    load_we <= '0';
    next_cmd;
    for cyc in 0 to STOP / 8 - 1 loop
      now_u := cyc * 8;
      if now_u >= 118 then resetn <= '1'; end if;

      -- host bus (GENERATOR.PAS timing), waits for INT/RDY before starting a write
      if phase = 0 and have_cmd and now_u >= t_cmd and intrdy = '1' then
        rd_cycle := a_cmd >= 4;
        csn <= '0'; wrn <= '1'; rdn <= '1';
        a <= std_logic_vector(to_unsigned(a_cmd mod 4, 2));
        if not rd_cycle then
          db_in <= std_logic_vector(to_unsigned(d_cmd, 8)); db_drive <= '1';
        end if;
        t_wr := now_u; phase := 1;
      elsif phase = 1 and now_u >= t_wr + 59 then
        if rd_cycle then rdn <= '0'; else wrn <= '0'; end if;
        phase := 2;
      elsif phase = 2 and now_u >= t_wr + 118 then
        if rd_cycle then
          rdn <= '1';
          if READ_FILE /= "" then
            write(l, now_u); write(l, string'(" ")); write(l, a_cmd mod 4); write(l, string'(" "));
            write(l, to_hstring(db_out)); writeline(fr, l);
          end if;
        else
          wrn <= '1';
        end if;
        phase := 3;
      elsif phase = 3 and now_u >= t_wr + 120 then
        csn <= '1'; db_drive <= '0'; phase := 0;
        next_cmd;
      end if;

      -- idle clocks, then the step itself
      loop
        acc := acc + STEP_NUM;
        exit when acc >= STEP_DEN;
        tick('0');
      end loop;
      acc := acc - STEP_DEN;
      tick('1');
      stepn <= stepn + 1;

      if outstbn /= last_strobe then
        write(l, now_u); write(l, string'(" "));
        write(l, std_logic'image(outstbn)(2)); write(l, string'(" "));
        write(l, to_hstring(samp)); write(l, string'(" "));
        write(l, to_string(samp));
        writeline(fo, l);
        last_strobe := outstbn;
      end if;
    end loop;
    report "done" severity note;
    std.env.finish;
  end process;

  -- RAM write trace (the memories' ports), for comparing restructured cores
  trace: if TRACE_FILE /= "" generate
    alias h_we  is <<signal .tb_amy1.dut.harmcurntval_we    : std_logic>>;
    alias h_a   is <<signal .tb_amy1.dut.harmcurntval_addr  : std_logic_vector(5 downto 0)>>;
    alias h_d   is <<signal .tb_amy1.dut.harmcurntval_wdata : std_logic_vector(12 downto 0)>>;
    alias b_we  is <<signal .tb_amy1.dut.harmbrkpoint_we    : std_logic>>;
    alias b_a   is <<signal .tb_amy1.dut.harmbrkpoint_addr  : std_logic_vector(5 downto 0)>>;
    alias b_d   is <<signal .tb_amy1.dut.harmbrkpoint_wdata : std_logic_vector(15 downto 0)>>;
    alias l_we  is <<signal .tb_amy1.dut.lhpram_we          : std_logic>>;
    alias l_a   is <<signal .tb_amy1.dut.lhpram_addr        : std_logic_vector(5 downto 0)>>;
    alias l_d   is <<signal .tb_amy1.dut.lhpram_wdata       : std_logic_vector(0 downto 0)>>;
    alias v_we  is <<signal .tb_amy1.dut.voice18_we         : std_logic>>;
    alias v_a   is <<signal .tb_amy1.dut.voice18_addr       : std_logic_vector(3 downto 0)>>;
    alias v_d   is <<signal .tb_amy1.dut.voice18_wdata      : std_logic_vector(17 downto 0)>>;
    alias w_we  is <<signal .tb_amy1.dut.voice3_we          : std_logic>>;
    alias w_a   is <<signal .tb_amy1.dut.voice3_addr        : std_logic_vector(3 downto 0)>>;
    alias w_d   is <<signal .tb_amy1.dut.voice3_wdata       : std_logic_vector(2 downto 0)>>;
    alias n_we  is <<signal .tb_amy1.dut.noise_we           : std_logic>>;
    alias n_a   is <<signal .tb_amy1.dut.noise_addr         : std_logic_vector(5 downto 0)>>;
    alias n_d   is <<signal .tb_amy1.dut.noise_wdata        : std_logic_vector(2 downto 0)>>;
    alias p_we  is <<signal .tb_amy1.dut.phaseram_we        : std_logic>>;
    alias p_a   is <<signal .tb_amy1.dut.phaseram_addr      : std_logic_vector(2 downto 0)>>;
    alias p_d   is <<signal .tb_amy1.dut.phaseram_wdata     : std_logic_vector(19 downto 0)>>;
  begin
    process (clk)
      file ft : text open write_mode is TRACE_FILE;
      variable l : line;
      procedure put(name : string; a, d : std_logic_vector) is
      begin
        write(l, stepn); write(l, string'(" ") & name & " ");
        write(l, to_hstring(a)); write(l, string'(" ")); write(l, to_hstring(d));
        writeline(ft, l);
      end procedure;
    begin
      if rising_edge(clk) and step_en = '1' then
        if h_we = '1' then put("hcv", h_a, h_d); end if;
        if b_we = '1' then put("hbp", b_a, b_d); end if;
        if l_we = '1' then put("lhp", l_a, l_d); end if;
        if v_we = '1' then put("v18", v_a, v_d); end if;
        if w_we = '1' then put("v3 ", w_a, w_d); end if;
        if n_we = '1' then put("nz ", n_a, n_d); end if;
        if p_we = '1' then put("ph ", p_a, p_d); end if;
      end if;
    end process;
  end generate;

end architecture;
