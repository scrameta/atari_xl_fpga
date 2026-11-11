-------------------------------------------------------------------------------
-- Testbench for amy1_top at 57.344 MHz. Host writes ("time addr data" per line,
-- 5 ns units, one chip step = 8 units) are pulsed on WRITE_ENABLE during the first
-- clock of step time/8 (amy1_top still makes six steps per chip clock; ce is the sixth).
-- Logs DBG_SAMP (the sample, two's complement) on every DBG_OUTSTBN edge (time = step * 8)
-- and every output (PCM_FILE). BUSY_FILE: per chip clock, each command's busy start
-- ("clock CMND") and, with NZ_ALL or in NZINIT, every Noise RAM write ("N clock addr data").
-- addr 8+r reads register r and logs it; addr 16+r writes register r (8..15, the
-- note engine; EVENT waits while the engine's queue is full). With ENGINE, CHIP_FILE
-- logs every chip write ("W step addr data", from the register port), every sample
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
    NZ_ALL    : boolean := false;
    NZ_WORDS  : boolean := false          -- BUSY_FILE also logs every new noise word ("Z clock gen word")
  );
end entity;

architecture sim of tb_top is
  -- Portable VHDL-93 file format helpers (no VHDL-2008 to_hstring).
  function nibble(c : character) return std_logic_vector is
  begin
    case c is
      when '0' => return "0000";
      when '1' => return "0001";
      when '2' => return "0010";
      when '3' => return "0011";
      when '4' => return "0100";
      when '5' => return "0101";
      when '6' => return "0110";
      when '7' => return "0111";
      when '8' => return "1000";
      when '9' => return "1001";
      when 'a' | 'A' => return "1010";
      when 'b' | 'B' => return "1011";
      when 'c' | 'C' => return "1100";
      when 'd' | 'D' => return "1101";
      when 'e' | 'E' => return "1110";
      when 'f' | 'F' => return "1111";
      when others => assert false report "non-hex input" severity failure;
                     return "0000";
    end case;
  end function;

  function hex_digits(v : std_logic_vector) return string is
    constant n : natural := (v'length + 3) / 4;
    variable padded : std_logic_vector(n*4-1 downto 0) := (others => '0');
    variable result : string(1 to n);
    variable code : integer;
  begin
    padded(v'length-1 downto 0) := v;
    for i in 0 to n-1 loop
      code := to_integer(unsigned(padded((n-i)*4-1 downto (n-i-1)*4)));
      if code < 10 then
        result(i+1) := character'val(character'pos('0')+code);
      else
        result(i+1) := character'val(character'pos('A')+code-10);
      end if;
    end loop;
    return result;
  end function;

  function sl_char(v : std_logic) return character is
  begin
    if v = '0' then return '0';
    elsif v = '1' then return '1';
    else return 'X'; end if;
  end function;

  function bit_digits(v : std_logic_vector) return string is
    variable result : string(1 to v'length);
    variable bit_no : natural := 1;
  begin
    for i in v'range loop
      if v(i) = '1' then result(bit_no) := '1';
      elsif v(i) = '0' then result(bit_no) := '0';
      else result(bit_no) := 'X'; end if;
      bit_no := bit_no + 1;
    end loop;
    return result;
  end function;

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
    variable hex_c : character;
    variable word_v : std_logic_vector(31 downto 0);
  begin
    while not endfile(fm) loop
      readline(fm, l);
      word_v := (others => '0');
      for k in 7 downto 0 loop
        read(l, hex_c);
        word_v(k*4+3 downto k*4) := nibble(hex_c);
      end loop;
      image(n) := word_v;
      n := n + 1;
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

  -- VHDL-93 note: the old chiplog/busylog test blocks use VHDL-2008
  -- external names, which cannot be expressed without changing the DUT ports.
  -- This portable bench checks the full public output stream and reads.

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
        write(l, string'(" = ")); write(l, hex_digits(do_s)); writeline(fr, l);
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
          write(l, sl_char(outstbn)); write(l, string'(" "));
          if V0_COL then write(l, sl_char(v0)); write(l, string'(" ")); end if;
          write(l, hex_digits(samp)); write(l, string'(" "));
          write(l, bit_digits(samp));
          writeline(fo, l);
          last_strobe := outstbn;
        end if;
        step := step + 1;
        first := true;
      end if;
    end loop;
    report "done";
    wait;
  end process;
end architecture;
