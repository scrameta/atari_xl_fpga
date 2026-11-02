---------------------------------------------------------------------------
-- AMY1 for PokeyMAX
--
-- Wraps the generated chip model (amy1 = amy1_core + amy1_mem) with:
--   * a memory loader: after reset all AMY memories (ROM tables included) are
--     filled from flash through the ROM_ADDR/ROM_REQUEST/ROM_READY/ROM_DATA
--     interface, from the image amy1_mem.bin placed at word address ROM_BASE.
--     The chip is held in reset until that is done.
--   * a step enable, either
--       USE_TICK = false: STEP_NUM/STEP_DEN of CLK, e.g. 375/896 of 57.344 MHz
--         = 24 MHz of steps, which is an 8 MHz AMY (31.25 kHz output, A = 440 Hz)
--       USE_TICK = true:  CHIP_CLK_TICK pulses are the AMY's CLOCK input edges;
--         each gives 3 steps, STEP_SPACING clocks apart. A pulse on every PHI2
--         edge makes a 2 x PHI2 = 3.55 MHz AMY (13.9 kHz output with 64
--         harmonics, 22.2 kHz with 40), locked to the Atari's clock.
--   * the host interface. The 6502 writes at full speed into a FIFO; each write
--     is replayed to the chip's bus pins. A, B and C are plain latches, so their
--     writes go straight through; after a command write the next one waits
--     until INT/RDY is high again. After a read command (read frequency $18+v, read amplitude
--     $C0+h) the wrapper reads the chip's B and C registers into shadows, so
--     6502 reads are answered at once:
--       write 0..3   the chip's command, A, B and C registers (through the FIFO)
--       write $00-$07 to the command register (not AMY commands; the chip never
--                    finishes them) resets the chip and drops queued writes.
--       read  0, 1   status: bit 7 = busy (writes pending, a read-back or a
--                    reset in progress, memories loading), bit 6 = FIFO full
--       read  2, 3   B and C from the last read command (valid when not busy).
--                    Frequency: B bits 4..0 and C = the 13-bit current value (B's
--                    top 3 bits read as 1). Amplitude: C.
--       4 r/w        VOICE_LEFT:  voices on the left channel  (INDIVIDUAL mode)
--       5 r/w        VOICE_RIGHT: voices on the right channel (bit n = voice n)
--       6 r/w        VOLUME: output x VOLUME/32 (32 = x1, $FF = x7.97, the default)
--       7 read       status, as 0
--       8..15        the note engine (ENGINE = true), see amy1_engine.vhd;
--                    without it they read as status and ignore writes. The
--                    engine's chip writes share the FIFO with the host's, after
--                    them: write 0..3 (including a reset) only while the
--                    engine's STATUS (register 14) says it is idle
--     If INT/RDY ever stays low for 255 internal clocks the chip is reset too.
--   * output volume: the chip leaves headroom for 64 full-scale harmonics, so
--     music is quiet. VOLUME (register 6) scales the output by VOLUME/32,
--     saturating at 16 bits; one multiplier per channel.
--   * stereo output: in SUM mode both channels carry the chip's sample; in
--     INDIVIDUAL mode (system options bit 2) every voice is a separate sample
--     and VOICE_LEFT/VOICE_RIGHT (registers 4, 5) choose the channels
--
-- Chip pins only ever change at the start of sequencer step 0. The loop
-- analysis in vhdlgen.py assumes this (see stepcut.py).
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.amy1_mem_pkg.all;

entity amy1_top is
  generic (
    STEP_NUM     : natural := 375;
    STEP_DEN     : natural := 896;
    USE_TICK     : boolean := false;
    STEP_SPACING : natural := 4;                       -- CLKs between steps (USE_TICK)
    FIFO_LOG2    : natural := 2;                       -- host write FIFO: 2**FIFO_LOG2 entries
    STEREO       : boolean := true;                    -- false: mono (use SUM mode), saves ~120 LEs
    ROM_BASE     : natural := 0;                       -- word address of amy1_mem.bin
    ENGINE       : boolean := false;                   -- the note engine, registers 8..15
    ENGINE_GLIDE : boolean := true;                    -- ... with glide slopes (~25 LEs)
    ENGINE_UNIT_LOG2 : natural := 14                   -- ... time unit: 14 at 2 x PHI2, 15 at 4 x PHI2
  );
  port (
    CLK          : in  std_logic;
    RESET_N      : in  std_logic;
    CHIP_CLK_TICK: in  std_logic := '0';               -- one CLK pulse per AMY clock edge (USE_TICK)

    -- host (registered on the PokeyMAX side)
    ADDR         : in  std_logic_vector(3 downto 0);   -- 0..3 the chip, 4..7 wrapper, 8..15 engine
    WRITE_ENABLE : in  std_logic;                      -- one CLK pulse per 6502 write
    DI           : in  std_logic_vector(7 downto 0);
    DO           : out std_logic_vector(7 downto 0);   -- status / read-back, see above

    -- flash, as for the SID (request held until ready; data valid with ready)
    ROM_ADDR     : out std_logic_vector(16 downto 0);
    ROM_DATA     : in  std_logic_vector(31 downto 0);
    ROM_REQUEST  : out std_logic;
    ROM_READY    : in  std_logic;

    -- output
    AUDIO_L      : out signed(15 downto 0);
    AUDIO_R      : out signed(15 downto 0);
    SAMPLE_STROBE: out std_logic;                      -- one CLK pulse per new L/R pair
    READY        : out std_logic;                      -- memories loaded, chip running

    -- for testbenches (leave open)
    DBG_STEP_EN  : out std_logic;
    DBG_SAMP     : out std_logic_vector(15 downto 0);  -- SAMP pins
    DBG_OUTSTBN  : out std_logic;
    DBG_V0       : out std_logic
  );
end entity;

architecture vhdl of amy1_top is
  function to_sl(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;

  -- saturate to 16 bits
  function sat16(y : signed) return signed is
  begin
    if y > 32767 then
      return to_signed(32767, 16);
    elsif y < -32768 then
      return to_signed(-32768, 16);
    end if;
    return resize(y, 16);
  end function;

  ---------------------------------------------------------------------------
  -- memory loader
  signal load_idx_reg, load_idx_next : unsigned(AMY1_LOAD_AW - 1 downto 0) := (others => '0');
  signal loaded_reg, loaded_next     : std_logic := '0';
  signal load_we                     : std_logic;

  ---------------------------------------------------------------------------
  -- step enable
  signal acc_reg, acc_next         : unsigned(15 downto 0) := (others => '0');
  signal step_en                   : std_logic;
  signal phase_reg, phase_next     : unsigned(2 downto 0) := (others => '0');   -- = core step
  signal pending_reg, pending_next : unsigned(3 downto 0) := (others => '0');   -- steps owed (USE_TICK)
  signal space_reg, space_next     : unsigned(3 downto 0) := (others => '0');
  signal tick                      : std_logic;    -- bus tick: end of step 5, pins change after it

  -- note engine
  signal eng_cpu_we, eng_push_req, eng_push_ack : std_logic;
  signal eng_push_addr               : std_logic_vector(1 downto 0);
  signal eng_push_data, eng_do       : std_logic_vector(7 downto 0);
  signal aux_re, aux_rack, aux_we, aux_wack : std_logic;
  signal aux_raddr, aux_waddr        : std_logic_vector(7 downto 0);
  signal aux_rdata, aux_wdata        : std_logic_vector(35 downto 0);

  ---------------------------------------------------------------------------
  -- write FIFO: 2**FIFO_LOG2 x {addr, data}
  constant FIFO_SIZE : natural := 2 ** FIFO_LOG2;
  type fifo_t is array (0 to FIFO_SIZE - 1) of std_logic_vector(9 downto 0);
  signal fifo_reg, fifo_next     : fifo_t := (others => (others => '0'));
  signal rd_ptr_reg, rd_ptr_next : unsigned(FIFO_LOG2 - 1 downto 0) := (others => '0');
  signal wr_ptr_reg, wr_ptr_next : unsigned(FIFO_LOG2 - 1 downto 0) := (others => '0');
  signal count_reg, count_next   : unsigned(FIFO_LOG2 downto 0) := (others => '0');
  signal full                    : std_logic;
  signal individual_reg, individual_next : std_logic := '0';   -- system options bit 2
  signal reset_req_reg, reset_req_next   : std_logic := '0';   -- host asked for a chip reset
  signal reset_taken             : std_logic;                  -- ... and it starts now

  -- wrapper registers
  signal voice_l_reg, voice_l_next : std_logic_vector(7 downto 0) := (others => '1');
  signal voice_r_reg, voice_r_next : std_logic_vector(7 downto 0) := (others => '1');
  signal volume_reg, volume_next   : std_logic_vector(7 downto 0) := (others => '1');

  ---------------------------------------------------------------------------
  -- chip bus cycles, one state per internal chip clock
  type bus_t is (bus_idle,
                 bus_setup, bus_strobe1, bus_strobe2, bus_release, bus_wait,       -- write
                 bus_rd_setup, bus_rd_strobe1, bus_rd_strobe2, bus_rd_release);    -- read B, C
  signal bus_reg, bus_next       : bus_t := bus_idle;
  signal gap_reg, gap_next       : unsigned(3 downto 0) := (others => '0');
  signal wait_reg, wait_next     : unsigned(7 downto 0) := (others => '0');  -- clocks waiting for RDY
  signal timeout                 : std_logic;
  signal cur_reg, cur_next       : std_logic_vector(9 downto 0) := (others => '0');
  signal csn_reg, csn_next       : std_logic := '1';
  signal wrn_reg, wrn_next       : std_logic := '1';
  signal rdn_reg, rdn_next       : std_logic := '1';
  signal drive_reg, drive_next   : std_logic := '0';
  signal resetn_reg, resetn_next : std_logic := '0';
  signal rstcnt_reg, rstcnt_next : unsigned(3 downto 0) := to_unsigned(3, 4);  -- reset clocks left
  signal shadow_b_reg, shadow_b_next : std_logic_vector(7 downto 0) := (others => '0');
  signal shadow_c_reg, shadow_c_next : std_logic_vector(7 downto 0) := (others => '0');
  signal db_out                  : std_logic_vector(7 downto 0);
  signal intrdy                  : std_logic;
  signal busy                    : std_logic;
  constant GAP : natural := 6;   -- internal clocks after a write before RDY is valid

  ---------------------------------------------------------------------------
  -- output
  signal samp_latch  : std_logic_vector(16 downto 0);
  signal outstbn     : std_logic;
  signal v0          : std_logic;
  signal outstbn_reg : std_logic := '1';
  signal voice_reg, voice_next   : unsigned(2 downto 0) := (others => '0');
  signal acc_l_reg, acc_l_next   : signed(19 downto 0) := (others => '0');
  signal acc_r_reg, acc_r_next   : signed(19 downto 0) := (others => '0');
  signal out_l_reg, out_l_next   : signed(19 downto 0) := (others => '0');   -- before volume
  signal out_r_reg, out_r_next   : signed(19 downto 0) := (others => '0');
  signal strobe_reg, strobe_next : std_logic := '0';
  signal aud_l_reg, aud_l_next   : signed(15 downto 0) := (others => '0');   -- after volume
  signal aud_r_reg, aud_r_next   : signed(15 downto 0) := (others => '0');
  signal aud_strobe_reg          : std_logic := '0';
begin
  ---------------------------------------------------------------------------
  -- registers
  process (CLK, RESET_N)
  begin
    if RESET_N = '0' then
      load_idx_reg   <= (others => '0');
      loaded_reg     <= '0';
      acc_reg        <= (others => '0');
      phase_reg      <= (others => '0');
      pending_reg    <= (others => '0');
      space_reg      <= (others => '0');
      rd_ptr_reg     <= (others => '0');
      wr_ptr_reg     <= (others => '0');
      count_reg      <= (others => '0');
      individual_reg <= '0';
      reset_req_reg  <= '0';
      voice_l_reg    <= (others => '1');
      voice_r_reg    <= (others => '1');
      volume_reg     <= (others => '1');
      bus_reg        <= bus_idle;
      gap_reg        <= (others => '0');
      wait_reg       <= (others => '0');
      cur_reg        <= (others => '0');
      csn_reg        <= '1';
      wrn_reg        <= '1';
      rdn_reg        <= '1';
      drive_reg      <= '0';
      resetn_reg     <= '0';
      rstcnt_reg     <= to_unsigned(3, 4);
      shadow_b_reg   <= (others => '0');
      shadow_c_reg   <= (others => '0');
      outstbn_reg    <= '1';
      voice_reg      <= (others => '0');
      acc_l_reg      <= (others => '0');
      acc_r_reg      <= (others => '0');
      out_l_reg      <= (others => '0');
      out_r_reg      <= (others => '0');
      strobe_reg     <= '0';
      aud_l_reg      <= (others => '0');
      aud_r_reg      <= (others => '0');
      aud_strobe_reg <= '0';
    elsif rising_edge(CLK) then
      load_idx_reg   <= load_idx_next;
      loaded_reg     <= loaded_next;
      acc_reg        <= acc_next;
      phase_reg      <= phase_next;
      pending_reg    <= pending_next;
      space_reg      <= space_next;
      fifo_reg       <= fifo_next;
      rd_ptr_reg     <= rd_ptr_next;
      wr_ptr_reg     <= wr_ptr_next;
      count_reg      <= count_next;
      individual_reg <= individual_next;
      reset_req_reg  <= reset_req_next;
      voice_l_reg    <= voice_l_next;
      voice_r_reg    <= voice_r_next;
      volume_reg     <= volume_next;
      bus_reg        <= bus_next;
      gap_reg        <= gap_next;
      wait_reg       <= wait_next;
      cur_reg        <= cur_next;
      csn_reg        <= csn_next;
      wrn_reg        <= wrn_next;
      rdn_reg        <= rdn_next;
      drive_reg      <= drive_next;
      resetn_reg     <= resetn_next;
      rstcnt_reg     <= rstcnt_next;
      shadow_b_reg   <= shadow_b_next;
      shadow_c_reg   <= shadow_c_next;
      voice_reg      <= voice_next;
      acc_l_reg      <= acc_l_next;
      acc_r_reg      <= acc_r_next;
      out_l_reg      <= out_l_next;
      out_r_reg      <= out_r_next;
      strobe_reg     <= strobe_next;
      aud_l_reg      <= aud_l_next;
      aud_r_reg      <= aud_r_next;
      aud_strobe_reg <= strobe_reg;
      if step_en = '1' then
        outstbn_reg <= outstbn;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- memory loader: one image word per flash request
  process (load_idx_reg, loaded_reg, ROM_READY)
  begin
    load_idx_next <= load_idx_reg;
    loaded_next   <= loaded_reg;
    load_we       <= '0';
    if loaded_reg = '0' and ROM_READY = '1' then
      load_we       <= '1';
      load_idx_next <= load_idx_reg + 1;
      if load_idx_reg = AMY1_LOAD_WORDS - 1 then
        loaded_next <= '1';
      end if;
    end if;
  end process;

  ROM_REQUEST <= not loaded_reg;
  ROM_ADDR    <= std_logic_vector(to_unsigned(ROM_BASE, 17) + resize(load_idx_reg, 17));
  READY       <= loaded_reg;

  ---------------------------------------------------------------------------
  -- step enable, once the memories are loaded
  process (acc_reg, phase_reg, pending_reg, space_reg, loaded_reg, CHIP_CLK_TICK)
    variable sum     : unsigned(15 downto 0);
    variable step    : std_logic;
    variable pending : unsigned(3 downto 0);
  begin
    sum := acc_reg + STEP_NUM;
    step         := '0';
    acc_next     <= acc_reg;
    pending_next <= pending_reg;
    space_next   <= space_reg;
    if loaded_reg = '1' then
      if not USE_TICK then
        -- STEP_NUM steps per STEP_DEN clocks
        acc_next <= sum;
        if sum >= STEP_DEN then
          step     := '1';
          acc_next <= sum - STEP_DEN;
        end if;
      else
        -- 3 steps per AMY clock edge, STEP_SPACING clocks apart
        pending := pending_reg;
        if CHIP_CLK_TICK = '1' then
          pending := pending + 3;
        end if;
        if space_reg /= 0 then
          space_next <= space_reg - 1;
        elsif pending /= 0 then
          step       := '1';
          pending    := pending - 1;
          space_next <= to_unsigned(STEP_SPACING - 1, 4);
        end if;
        pending_next <= pending;
      end if;
    end if;

    step_en    <= step;
    phase_next <= phase_reg;
    if step = '1' then
      if phase_reg = 5 then
        phase_next <= (others => '0');
      else
        phase_next <= phase_reg + 1;
      end if;
    end if;
  end process;

  tick <= step_en and to_sl(phase_reg = 5);

  -- a chip reset starts at the next bus tick after it is asked for, or when
  -- INT/RDY has been low for 255 internal clocks (commands take about 10)
  reset_taken <= reset_req_reg and tick;
  timeout     <= tick and to_sl(bus_reg = bus_wait and wait_reg = 255) and not intrdy;

  ---------------------------------------------------------------------------
  -- host writes go into the FIFO
  process (fifo_reg, wr_ptr_reg, rd_ptr_reg, count_reg, full, individual_reg, reset_req_reg,
           WRITE_ENABLE, ADDR, DI, bus_reg, resetn_reg, tick, reset_taken, timeout,
           eng_push_req, eng_push_addr, eng_push_data)
    variable reset_cmd, push, eng, pop : std_logic;
    variable entry : std_logic_vector(9 downto 0);
  begin
    fifo_next       <= fifo_reg;
    wr_ptr_next     <= wr_ptr_reg;
    rd_ptr_next     <= rd_ptr_reg;
    count_next      <= count_reg;
    individual_next <= individual_reg;
    reset_req_next  <= reset_req_reg;
    if reset_taken = '1' then
      reset_req_next <= '0';
    end if;

    -- command bytes $00-$07 reset the chip (see the header)
    reset_cmd := '0';
    if WRITE_ENABLE = '1' and ADDR = "0000" and DI(7 downto 3) = "00000" then
      reset_cmd := '1';
    end if;

    -- the host's writes, else the engine's
    push := '0';
    eng  := '0';
    entry := ADDR(1 downto 0) & DI;
    if WRITE_ENABLE = '1' and ADDR(3 downto 2) = "00" and reset_cmd = '0' and full = '0' then
      push := '1';
    elsif eng_push_req = '1' and reset_cmd = '0' and timeout = '0' and full = '0' then
      push := '1';
      eng  := '1';
      entry := eng_push_addr & eng_push_data;
    end if;
    eng_push_ack <= eng;
    pop := '0';
    if tick = '1' and bus_reg = bus_idle and count_reg /= 0 and resetn_reg = '1'
       and reset_req_reg = '0' then
      pop := '1';
    end if;

    if reset_cmd = '1' or timeout = '1' then
      wr_ptr_next    <= (others => '0');
      rd_ptr_next    <= (others => '0');
      count_next     <= (others => '0');
      reset_req_next <= reset_cmd;
    else
      if push = '1' then
        fifo_next(to_integer(wr_ptr_reg)) <= entry;
        wr_ptr_next <= wr_ptr_reg + 1;
        -- snoop "write system options" for the output format
        if eng = '0' and ADDR = "0000" and DI(7 downto 4) = "0010" then
          individual_next <= DI(2);
        end if;
      end if;
      if pop = '1' then
        rd_ptr_next <= rd_ptr_reg + 1;
      end if;
      if push = '1' and pop = '0' then
        count_next <= count_reg + 1;
      elsif push = '0' and pop = '1' then
        count_next <= count_reg - 1;
      end if;
    end if;
  end process;

  full <= count_reg(FIFO_LOG2);

  -- wrapper registers 4..6, written directly
  process (voice_l_reg, voice_r_reg, volume_reg, WRITE_ENABLE, ADDR, DI)
  begin
    voice_l_next <= voice_l_reg;
    voice_r_next <= voice_r_reg;
    volume_next  <= volume_reg;
    if WRITE_ENABLE = '1' then
      case ADDR is
        when "0100" => voice_l_next <= DI;
        when "0101" => voice_r_next <= DI;
        when "0110" => volume_next  <= DI;
        when others => null;
      end case;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- chip bus: one state per internal chip clock, changing as step 0 starts
  --   write:  setup (CS low, address and data) - WR low for two internal clocks -
  --           release (WR, then CS high) - wait GAP clocks, then for INT/RDY
  --   read:   after a read command, the same with RD low for B, then for C;
  --           the data bus is taken as RD goes high
  process (bus_reg, gap_reg, wait_reg, cur_reg, csn_reg, wrn_reg, rdn_reg, drive_reg,
           resetn_reg, rstcnt_reg, shadow_b_reg, shadow_c_reg, fifo_reg, rd_ptr_reg,
           count_reg, reset_req_reg, tick, reset_taken, timeout, intrdy, db_out)
    variable rd_cmd : boolean;
  begin
    bus_next      <= bus_reg;
    gap_next      <= gap_reg;
    wait_next     <= wait_reg;
    cur_next      <= cur_reg;
    csn_next      <= csn_reg;
    wrn_next      <= wrn_reg;
    rdn_next      <= rdn_reg;
    drive_next    <= drive_reg;
    resetn_next   <= resetn_reg;
    rstcnt_next   <= rstcnt_reg;
    shadow_b_next <= shadow_b_reg;
    shadow_c_next <= shadow_c_reg;

    -- the command just written reads something back: $18-$1F frequency, $C0-$FF amplitude
    rd_cmd := cur_reg(9 downto 8) = "00" and
              (cur_reg(7 downto 3) = "00011" or cur_reg(7 downto 6) = "11");

    if reset_taken = '1' or timeout = '1' then
      -- chip reset: 8 internal clocks (the spec asks for at least 10 CLOCK periods = 5)
      resetn_next <= '0';
      rstcnt_next <= to_unsigned(8, 4);
      bus_next    <= bus_idle;
      csn_next    <= '1';
      wrn_next    <= '1';
      rdn_next    <= '1';
      drive_next  <= '0';
    elsif tick = '1' then
      -- chip in reset until the count runs out (4 internal clocks after power up)
      if rstcnt_reg = 0 then
        resetn_next <= '1';
      else
        resetn_next <= '0';
        rstcnt_next <= rstcnt_reg - 1;
      end if;

      case bus_reg is
        when bus_idle =>
          if count_reg /= 0 and resetn_reg = '1' and reset_req_reg = '0' then
            cur_next   <= fifo_reg(to_integer(rd_ptr_reg));
            csn_next   <= '0';
            drive_next <= '1';
            bus_next   <= bus_setup;
          end if;

        -- write cycle
        when bus_setup =>
          wrn_next <= '0';
          bus_next <= bus_strobe1;
        when bus_strobe1 =>
          bus_next <= bus_strobe2;
        when bus_strobe2 =>
          wrn_next <= '1';
          bus_next <= bus_release;
        when bus_release =>
          csn_next   <= '1';
          drive_next <= '0';
          if cur_reg(9 downto 8) = "00" then
            -- a command: INT/RDY drops until the chip has executed it
            gap_next  <= to_unsigned(GAP, 4);
            wait_next <= (others => '0');
            bus_next  <= bus_wait;
          else
            -- A, B, C are plain latches: the next write can follow at once
            bus_next  <= bus_idle;
          end if;
        when bus_wait =>
          if wait_reg /= 255 then
            wait_next <= wait_reg + 1;
          end if;
          if gap_reg /= 0 then
            gap_next <= gap_reg - 1;
          elsif intrdy = '1' then
            if rd_cmd then
              cur_next <= "10" & cur_reg(7 downto 0);    -- read B first
              csn_next <= '0';
              bus_next <= bus_rd_setup;
            else
              bus_next <= bus_idle;
            end if;
          end if;

        -- read cycle (register in cur_reg(9 downto 8))
        when bus_rd_setup =>
          rdn_next <= '0';
          bus_next <= bus_rd_strobe1;
        when bus_rd_strobe1 =>
          bus_next <= bus_rd_strobe2;
        when bus_rd_strobe2 =>
          if cur_reg(8) = '0' then
            shadow_b_next <= db_out;
          else
            shadow_c_next <= db_out;
          end if;
          rdn_next <= '1';
          bus_next <= bus_rd_release;
        when bus_rd_release =>
          if cur_reg(8) = '0' then
            cur_next <= "11" & cur_reg(7 downto 0);    -- then C
            bus_next <= bus_rd_setup;
          else
            csn_next <= '1';
            bus_next <= bus_idle;
          end if;
      end case;
    end if;
  end process;

  -- status / read-back
  busy <= '0' when count_reg = 0 and bus_reg = bus_idle and loaded_reg = '1'
                   and resetn_reg = '1' and reset_req_reg = '0' else '1';
  with ADDR select DO <=
    shadow_b_reg           when "0010",
    shadow_c_reg           when "0011",
    voice_l_reg            when "0100",
    voice_r_reg            when "0101",
    volume_reg             when "0110",
    eng_do                 when "1000" | "1001" | "1010" | "1011" | "1100" | "1101" | "1110" | "1111",
    busy & full & "000000" when others;

  ---------------------------------------------------------------------------
  -- the note engine
  engine_on: if ENGINE generate
    eng: entity work.amy1_engine generic map (GLIDE => ENGINE_GLIDE, UNIT_LOG2 => ENGINE_UNIT_LOG2) port map (
      clk       => CLK,
      reset_n   => RESET_N,
      tick      => tick,
      cpu_we    => eng_cpu_we,
      cpu_addr  => ADDR(2 downto 0),
      cpu_di    => DI,
      cpu_do    => eng_do,
      aux_re    => aux_re,
      aux_raddr => aux_raddr,
      aux_rack  => aux_rack,
      aux_rdata => aux_rdata,
      aux_we    => aux_we,
      aux_waddr => aux_waddr,
      aux_wdata => aux_wdata,
      aux_wack  => aux_wack,
      push_req  => eng_push_req,
      push_addr => eng_push_addr,
      push_data => eng_push_data,
      push_ack  => eng_push_ack);
  end generate;
  eng_cpu_we <= WRITE_ENABLE and ADDR(3);

  engine_off: if not ENGINE generate
    eng_do        <= busy & full & "000000";
    aux_re        <= '0';
    aux_raddr     <= (others => '0');
    aux_we        <= '0';
    aux_waddr     <= (others => '0');
    aux_wdata     <= (others => '0');
    eng_push_req  <= '0';
    eng_push_addr <= "00";
    eng_push_data <= (others => '0');
  end generate;

  ---------------------------------------------------------------------------
  -- the chip
  chip: entity work.amy1 port map (
    clk          => CLK,
    step_en      => step_en,
    pin_resetn   => resetn_reg,
    pin_test     => '0',
    pin_oen      => '0',
    pin_csn      => csn_reg,
    pin_wrn      => wrn_reg,
    pin_rdn      => rdn_reg,
    pin_a        => cur_reg(9 downto 8),
    pin_db_in    => cur_reg(7 downto 0),
    pin_db_drive => drive_reg,
    pin_db_out   => db_out,
    pin_db_oe    => open,
    pin_intrdy   => intrdy,
    pin_samp     => DBG_SAMP,
    pin_outstbn  => outstbn,
    pin_v0       => v0,
    samp_latch   => samp_latch,
    samp_load    => open,
    load_we      => load_we,
    load_addr    => std_logic_vector(load_idx_reg),
    load_data    => ROM_DATA,
    aux_re       => aux_re,
    aux_raddr    => aux_raddr,
    aux_rack     => aux_rack,
    aux_rdata    => aux_rdata,
    aux_we       => aux_we,
    aux_waddr    => aux_waddr,
    aux_wdata    => aux_wdata,
    aux_wack     => aux_wack
  );

  ---------------------------------------------------------------------------
  -- output: take the sample latch as OUTSTB starts (offset binary -> signed).
  --   SUM mode:        one sample per period, on both channels
  --   INDIVIDUAL mode: one sample per voice; V0 marks voice 0. The previous
  --                    period's left/right sums are output when voice 0 arrives.
  process (voice_reg, acc_l_reg, acc_r_reg, out_l_reg, out_r_reg, individual_reg, resetn_reg,
           step_en, outstbn, outstbn_reg, v0, samp_latch, voice_l_reg, voice_r_reg)
    variable s     : signed(19 downto 0);
    variable voice : unsigned(2 downto 0);
    variable l, r  : signed(19 downto 0);
  begin
    voice_next  <= voice_reg;
    acc_l_next  <= acc_l_reg;
    acc_r_next  <= acc_r_reg;
    out_l_next  <= out_l_reg;
    out_r_next  <= out_r_reg;
    strobe_next <= '0';

    if resetn_reg = '0' then
      -- chip in reset: its sample bus is meaningless, output silence
      out_l_next <= (others => '0');
      out_r_next <= (others => '0');
      acc_l_next <= (others => '0');
      acc_r_next <= (others => '0');
    elsif step_en = '1' and outstbn_reg = '1' and outstbn = '0' then
      s := resize(signed(not samp_latch(15) & samp_latch(14 downto 0)), 20);
      if individual_reg = '0' or not STEREO then
        out_l_next  <= s;
        out_r_next  <= s;
        strobe_next <= '1';
      else
        l := acc_l_reg;
        r := acc_r_reg;
        voice := voice_reg + 1;
        if v0 = '1' then
          out_l_next  <= acc_l_reg;
          out_r_next  <= acc_r_reg;
          strobe_next <= '1';
          l := (others => '0');
          r := (others => '0');
          voice := (others => '0');
        end if;
        if voice_l_reg(to_integer(voice)) = '1' then
          l := l + s;
        end if;
        if voice_r_reg(to_integer(voice)) = '1' then
          r := r + s;
        end if;
        acc_l_next <= l;
        acc_r_next <= r;
        voice_next <= voice;
      end if;
    end if;
  end process;

  -- volume: one clock after each new sample, x VOLUME / 32, saturated
  process (out_l_reg, out_r_reg, strobe_reg, aud_l_reg, aud_r_reg, volume_reg)
    variable vol  : signed(8 downto 0);
    variable l, r : signed(28 downto 0);
  begin
    aud_l_next <= aud_l_reg;
    aud_r_next <= aud_r_reg;
    vol := signed('0' & volume_reg);
    l := out_l_reg * vol;
    r := out_r_reg * vol;
    if strobe_reg = '1' then
      aud_l_next <= sat16(shift_right(l, 5));
      aud_r_next <= sat16(shift_right(r, 5));
    end if;
  end process;

  AUDIO_L       <= aud_l_reg;
  AUDIO_R       <= aud_r_reg;
  SAMPLE_STROBE <= aud_strobe_reg;
  DBG_STEP_EN   <= step_en;
  DBG_OUTSTBN   <= outstbn;
  DBG_V0        <= v0;
end architecture;
