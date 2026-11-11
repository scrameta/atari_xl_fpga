-------------------------------------------------------------------------------
-- Testbench for amy1_top at 57.344 MHz. Host writes ("time addr data" per line,
-- 5 ns units, one chip step = 8 units) are pulsed on WRITE_ENABLE during the first
-- clock of step time/8. Logs the SAMP pins on every OUTSTB edge (time = step * 8,
-- the format of the Verilator harnesses) and every SAMPLE value.
-- addr 8+r reads register r and logs it; addr 16+r writes register r (8..15, the
-- note engine; EVENT waits while the engine's queue is full). With ENGINE, CHIP_FILE
-- logs every chip write ("W step addr data", from the chip bus), every sample
-- ("S step") and the engine's time when it reads ("r now") and writes ("w now")
-- a voice state.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_top is
  generic (
    CMD_FILE : string  := "cmds.txt";
    OUT_FILE : string  := "samples.txt";
    PCM_FILE : string  := "pcm.txt";
    V0_COL   : boolean := false;
    READ_FILE : string := "reads.txt";
    STOP     : natural := 1300000;
    STEP_NUM : natural := 375;
    STEP_DEN : natural := 896;
    MEM_FILE : string  := "amy1_mem.hex";
    ROM_BASE : natural := 4096;
    VOICES_L : std_logic_vector(7 downto 0) := x"FF";
    VOICES_R : std_logic_vector(7 downto 0) := x"FF";
    TICK_EVERY : natural := 0;            -- > 0: USE_TICK with a tick every TICK_EVERY clocks
    STEP_SPACING : natural := 4;          -- clocks between the 3 steps of a tick (USE_TICK)
    UNIT_LOG2 : natural := 14;            -- the engine's time unit
    ENGINE   : boolean := false;
    CHIP_FILE : string := "chip.txt";
    BUSY_FILE : string := "busy.txt";
    NZ_ALL    : boolean := false
  );
end entity;

architecture sim of tb_top is
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal addr    : std_logic_vector(3 downto 0) := "0000";
  signal we      : std_logic := '0';
  signal di      : std_logic_vector(7 downto 0) := (others => '0');
  signal audio_l, audio_r : signed(15 downto 0);
  signal strobe, step_en, outstbn, v0 : std_logic;
  signal rom_addr    : std_logic_vector(16 downto 0);
  signal rom_data    : std_logic_vector(31 downto 0) := (others => '0');
  signal rom_request : std_logic;
  signal rom_ready   : std_logic := '0';
  signal samp    : std_logic_vector(15 downto 0);
  signal tick    : std_logic := '0';
  signal do_s    : std_logic_vector(7 downto 0);
begin
  dut: entity work.amy1_top
    generic map (STEP_NUM => STEP_NUM, STEP_DEN => STEP_DEN, ROM_BASE => ROM_BASE,
                 USE_TICK => TICK_EVERY > 0, STEP_SPACING => STEP_SPACING, ENGINE => ENGINE,
                 ENGINE_UNIT_LOG2 => UNIT_LOG2)
    port map (CLK => clk, RESET_N => reset_n, CHIP_CLK_TICK => tick, ADDR => addr, WRITE_ENABLE => we, DI => di, DO => do_s,
              ROM_ADDR => rom_addr, ROM_DATA => rom_data, ROM_REQUEST => rom_request, ROM_READY => rom_ready,
              AUDIO_L => audio_l, AUDIO_R => audio_r, SAMPLE_STROBE => strobe, READY => open,
              DBG_STEP_EN => step_en, DBG_SAMP => samp, DBG_OUTSTBN => outstbn, DBG_V0 => v0);

  -- flash: the image at ROM_BASE, answering a request after three clocks
  flash: process
    file fm : text open read_mode is MEM_FILE;
    type image_t is array (0 to 2047) of std_logic_vector(31 downto 0);
    variable image : image_t := (others => (others => '0'));
    variable l : line;
    variable n : natural := 0;
  begin
    while not endfile(fm) loop
      readline(fm, l); hread(l, image(n)); n := n + 1;
    end loop;
    loop
      wait until rising_edge(clk) and rom_request = '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rom_data  <= image(to_integer(unsigned(rom_addr)) - ROM_BASE);
      rom_ready <= '1';
      wait until rising_edge(clk);
      rom_ready <= '0';
    end loop;
  end process;

  -- AMY clock edges (e.g. both PHI2 edges)
  ticks: process
    variable n : natural := 0;
  begin
    wait until rising_edge(clk);
    if TICK_EVERY > 0 then
      n := n + 1;
      if n = TICK_EVERY then
        n := 0; tick <= '1';
      else
        tick <= '0';
      end if;
    end if;
  end process;

  -- the engine build: chip writes, samples and the engine's voice state times
  chiplog: if ENGINE generate
    process (clk)
      file fo : text open write_mode is CHIP_FILE;
      variable l : line;
      variable steps : natural := 0;
      variable wrn_last : std_logic := '1';
      variable vs_read : boolean := false;
      alias wrn is << signal .tb_top.dut.wrn_reg : std_logic >>;
      alias cur is << signal .tb_top.dut.cur_reg : std_logic_vector(9 downto 0) >>;
      alias rack is << signal .tb_top.dut.aux_rack : std_logic >>;
      alias raddr is << signal .tb_top.dut.aux_raddr : std_logic_vector(7 downto 0) >>;
      alias wack is << signal .tb_top.dut.aux_wack : std_logic >>;
      alias waddr is << signal .tb_top.dut.aux_waddr : std_logic_vector(7 downto 0) >>;
      alias now is << signal .tb_top.dut.engine_on.eng.now_reg : unsigned(7 downto 0) >>;
      alias pw is << signal .tb_top.dut.engine_on.eng.pw_reg : std_logic >>;
    begin
      if rising_edge(clk) then
        if wrn_last = '1' and wrn = '0' then
          write(l, string'("W ")); write(l, steps); write(l, string'(" "));
          write(l, to_integer(unsigned(cur(9 downto 8)))); write(l, string'(" "));
          write(l, to_integer(unsigned(cur(7 downto 0)))); writeline(fo, l);
        end if;
        wrn_last := wrn;
        if strobe = '1' then
          write(l, string'("S ")); write(l, steps); writeline(fo, l);
        end if;
        if vs_read then
          write(l, string'("r ")); write(l, to_integer(now)); writeline(fo, l);
        end if;
        vs_read := rack = '1' and raddr(7 downto 3) = "00100";
        if wack = '1' and waddr(7 downto 3) = "00100" and pw = '0' then
          write(l, string'("w ")); write(l, to_integer(now)); writeline(fo, l);
        end if;
        if step_en = '1' then
          steps := steps + 1;
        end if;
      end if;
    end process;
  end generate;

  -- busy starts, per chip clock (for the timing-deviation report)
  busylog: block
    alias b_tick is << signal .tb_top.dut.tick : std_logic >>;
    alias b_bsy  is << signal .tb_top.dut.chip.core.u_command_unit.bsy : std_logic >>;
    alias b_cmd  is << signal .tb_top.dut.chip.core.cmnd : std_logic_vector(7 downto 0) >>;
    alias n_init is << signal .tb_top.dut.chip.noise_init : std_logic >>;
    alias n_we   is << signal .tb_top.dut.chip.noise_we : std_logic >>;
    alias n_a    is << signal .tb_top.dut.chip.noise_addr : std_logic_vector(5 downto 0) >>;
    alias n_d    is << signal .tb_top.dut.chip.noise_wdata : std_logic_vector(2 downto 0) >>;
  begin
    process (clk)
      file fb : text open write_mode is BUSY_FILE;
      variable l : line;
      variable n : natural := 0;
      variable last : std_logic := '0';
    begin
      if rising_edge(clk) and b_tick = '1' then
        n := n + 1;
        if b_bsy = '1' and last = '0' then
          write(l, n); write(l, string'(" ")); write(l, to_hstring(b_cmd)); writeline(fb, l);
        end if;
        if n_we = '1' and (n_init = '1' or NZ_ALL) then
          write(l, string'("N ")); write(l, n); write(l, string'(" ")); write(l, to_hstring(n_a));
          write(l, string'(" ")); write(l, to_hstring(n_d)); writeline(fb, l);
        end if;
        last := b_bsy;
      end if;
    end process;
  end block;

  run: process
    file fc : text open read_mode is CMD_FILE;
    file fo : text open write_mode is OUT_FILE;
    file fp : text open write_mode is PCM_FILE;
    file fr : text open write_mode is READ_FILE;
    variable l : line;
    variable t_cmd, a_cmd, d_cmd : integer;
    variable have        : boolean := false;
    variable step        : natural := 0;      -- the step in progress
    variable init        : natural := 0;
    variable first       : boolean := true;   -- first clock of that step
    variable ending      : boolean;
    variable last_strobe : std_logic := 'U';

    procedure next_cmd is
    begin
      have := false;
      while not endfile(fc) loop
        readline(fc, l);
        if l'length > 0 then
          read(l, t_cmd); read(l, a_cmd); read(l, d_cmd); have := true; exit;
        end if;
      end loop;
    end procedure;

    procedure clock is
    begin
      wait for 4 ns;  clk <= '1';
      wait for 1 ns;
    end procedure;
  begin
    next_cmd;
    clock; reset_n <= '1';
    while step * 8 < STOP loop
      wait for 3 ns; clk <= '0';
      we <= '0';
      addr <= "0000";              -- reads (the FIFO-full poll) see the status register
      wait for 100 ps;
      if init < 2 then
        -- first: the stereo voice registers
        we <= '1';
        if init = 0 then addr <= "0100"; di <= VOICES_L; else addr <= "0101"; di <= VOICES_R; end if;
        init := init + 1;
      elsif first and have and t_cmd / 8 <= step and a_cmd >= 24 then
        -- "t 16+r d": write engine register r (EVENT once the queue has room)
        addr <= "1110";
        wait for 100 ps;
        if a_cmd /= 27 or do_s(6) = '0' then
          we   <= '1';
          addr <= std_logic_vector(to_unsigned(a_cmd - 16, 4));
          di   <= std_logic_vector(to_unsigned(d_cmd, 8));
          next_cmd;
        else
          addr <= "0000";
        end if;
      elsif first and have and t_cmd / 8 <= step and a_cmd >= 8 and do_s(7) = '0' then
        -- "t 8+r 0": once not busy, read register r and log it
        addr <= std_logic_vector(to_unsigned(a_cmd - 8, 4));
        wait for 100 ps;
        write(l, step * 8); write(l, string'(" read ")); write(l, a_cmd - 8);
        write(l, string'(" = ")); write(l, to_hstring(do_s)); writeline(fr, l);
        addr <= "0000";
        next_cmd;
      elsif first and have and t_cmd / 8 <= step and a_cmd < 8 and do_s(6) = '0' then   -- wait while the FIFO is full
        we   <= '1';
        addr <= std_logic_vector(to_unsigned(a_cmd, 4));
        di   <= std_logic_vector(to_unsigned(d_cmd, 8));
        next_cmd;
      end if;
      first := false;
      wait for 1 ns;
      ending := step_en = '1';
      clock;
      if strobe = '1' then
        write(l, to_integer(audio_l)); write(l, string'(" "));
        write(l, to_integer(audio_r)); writeline(fp, l);
      end if;
      if ending then
        if outstbn /= last_strobe then
          write(l, step * 8); write(l, string'(" "));
          write(l, std_logic'image(outstbn)(2)); write(l, string'(" "));
          if V0_COL then write(l, std_logic'image(v0)(2)); write(l, string'(" ")); end if;
          write(l, to_hstring(samp)); write(l, string'(" "));
          write(l, to_string(samp));
          writeline(fo, l);
          last_strobe := outstbn;
        end if;
        step := step + 1;
        first := true;
      end if;
    end loop;
    report "done";
    std.env.finish;
  end process;
end architecture;
