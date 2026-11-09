---------------------------------------------------------------------------
-- AMY1 for PokeyMAX
--
-- Wraps the chip (amy1 = amy1_core + amy1_mem) with:
--   * a memory loader: after reset all AMY memories (ROM tables included) are
--     filled from flash through the ROM_ADDR/ROM_REQUEST/ROM_READY/ROM_DATA
--     interface, from the image amy1_mem.bin placed at word address ROM_BASE.
--     The chip is held in reset until that is done.
--   * the chip clock enable ce (one per AMY internal clock, CLOCK / 2). Its rate is
--     given in steps of a sixth of a chip clock (three per CLOCK edge), as before:
--       USE_TICK = false: STEP_NUM/STEP_DEN of CLK, e.g. 375/896 of 57.344 MHz
--         = 24 MHz of steps, which is an 8 MHz AMY (31.25 kHz output, A = 440 Hz)
--       USE_TICK = true:  CHIP_CLK_TICK pulses are the AMY's CLOCK input edges;
--         each gives 3 steps, STEP_SPACING clocks apart. A pulse on every PHI2
--         edge makes a 2 x PHI2 = 3.55 MHz AMY (13.9 kHz output with 64
--         harmonics, 22.2 kHz with 40), locked to the Atari's clock.
--     ce is the sixth step, so ce is at least six clks apart (the packed memories
--     need three). Only ce clocks the chip: nothing in it needs a multicycle path
--     constraint, though one of 6 clks would be valid.
--   * the host interface. The 6502 writes at full speed into a FIFO; each write
--     goes to the chip's register port. A, B and C are plain registers, so their
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
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.amy1_mem_pkg.all;

entity amy1_top is
  generic (
    STEP_NUM     : natural := 3;
    STEP_DEN     : natural := 7;
    USE_TICK     : boolean := false;
    STEP_SPACING : natural := 4;                       -- CLKs between steps (USE_TICK)
    FIFO_LOG2    : natural := 2;                       -- host write FIFO: 2**FIFO_LOG2 entries
    STEREO       : boolean := true;                    -- false: mono (use SUM mode), saves ~120 LEs
    ROM_BASE     : natural := 0;                       -- word address of amy1_mem.bin
    ENGINE       : boolean := false;                   -- the note engine, registers 8..15
    ENGINE_GLIDE : boolean := true;                    -- ... with glide slopes (~25 LEs)
    ENGINE_UNIT_LOG2 : natural := 15                   -- ... time unit: 14 at 2 x PHI2, 15 at 4 x PHI2
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
    DBG_STEP_EN  : out std_logic;                      -- the step enable (six per ce)
    DBG_SAMP     : out std_logic_vector(15 downto 0);  -- the chip's sample, bits 15..0
    DBG_OUTSTBN  : out std_logic;                      -- low with a new sample
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
  signal tick                      : std_logic;    -- the chip clock enable (ce): the sixth step

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
  signal ext_enable_reg, ext_enable_next : std_logic := '0'; -- unlocked after $A5,$5A sequence
  signal ext_key_reg, ext_key_next       : std_logic := '0';
  signal ext_a_reg, ext_b_reg, ext_c_reg : std_logic_vector(7 downto 0) := (others => '0');
  signal ext_a_next, ext_b_next, ext_c_next : std_logic_vector(7 downto 0);
  signal ext_we, ext_clear, ext_ack : std_logic;
  signal ext_kind : std_logic_vector(1 downto 0);
  signal ext_index : std_logic_vector(5 downto 0);
  signal ext_value : std_logic_vector(7 downto 0);
  signal ext_command : std_logic;

  signal reset_taken             : std_logic;                  -- ... and it starts now

  -- wrapper registers
  signal voice_l_reg, voice_l_next : std_logic_vector(7 downto 0) := (others => '1');
  signal voice_r_reg, voice_r_next : std_logic_vector(7 downto 0) := (others => '1');
  signal volume_reg, volume_next   : std_logic_vector(7 downto 0) := (others => '1');

  ---------------------------------------------------------------------------
  -- chip register port
  type bus_t is (bus_idle, bus_wait, bus_rd_b, bus_rd_c, bus_ext_wait);
  signal bus_reg, bus_next       : bus_t := bus_idle;
  signal wait_reg, wait_next     : unsigned(7 downto 0) := (others => '0');  -- chip clocks waiting for RDY
  signal timeout                 : std_logic;
  signal cur_reg, cur_next       : std_logic_vector(9 downto 0) := (others => '0');
  signal chip_we                 : std_logic;
  signal chip_addr               : std_logic_vector(1 downto 0);
  signal chip_wdata              : std_logic_vector(7 downto 0);
  signal resetn_reg, resetn_next : std_logic := '0';
  signal up_reg, up_next         : std_logic := '0';   -- the chip's reset has ended (a ce after resetn)
  signal rstcnt_reg, rstcnt_next : unsigned(3 downto 0) := to_unsigned(3, 4);  -- reset clocks left
  signal shadow_b_reg, shadow_b_next : std_logic_vector(7 downto 0) := (others => '0');
  signal shadow_c_reg, shadow_c_next : std_logic_vector(7 downto 0) := (others => '0');
  signal rdata                   : std_logic_vector(7 downto 0);
  signal intrdy                  : std_logic;
  signal busy                    : std_logic;
  signal chip_reset              : std_logic;

  ---------------------------------------------------------------------------
  -- output
  signal sample      : signed(16 downto 0);
  signal sample_stb  : std_logic;
  signal v0          : std_logic;
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
      ext_enable_reg <= '0';
      ext_key_reg <= '0';
      ext_a_reg <= (others => '0');
      ext_b_reg <= (others => '0');
      ext_c_reg <= (others => '0');
      reset_req_reg  <= '0';
      voice_l_reg    <= (others => '1');
      voice_r_reg    <= (others => '1');
      volume_reg     <= (others => '1');
      bus_reg        <= bus_idle;
      wait_reg       <= (others => '0');
      cur_reg        <= (others => '0');
      resetn_reg     <= '0';
      up_reg         <= '0';
      rstcnt_reg     <= to_unsigned(3, 4);
      shadow_b_reg   <= (others => '0');
      shadow_c_reg   <= (others => '0');
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
      ext_enable_reg <= ext_enable_next;
      ext_key_reg <= ext_key_next;
      ext_a_reg <= ext_a_next;
      ext_b_reg <= ext_b_next;
      ext_c_reg <= ext_c_next;
      reset_req_reg  <= reset_req_next;
      voice_l_reg    <= voice_l_next;
      voice_r_reg    <= voice_r_next;
      volume_reg     <= volume_next;
      bus_reg        <= bus_next;
      wait_reg       <= wait_next;
      cur_reg        <= cur_next;
      resetn_reg     <= resetn_next;
      up_reg         <= up_next;
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
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- Revision C extension state, separated from the register process.
  -- 6502 writes to $D2C7 form the unlock sequence; the legacy command
  -- operands are shadowed as they reach the chip (including engine writes).
  process (ext_enable_reg, ext_key_reg, ext_a_reg, ext_b_reg, ext_c_reg,
           reset_taken, timeout, WRITE_ENABLE, ADDR, DI, busy,
           chip_we, chip_addr, chip_wdata)
  begin
    ext_enable_next <= ext_enable_reg;
    ext_key_next <= ext_key_reg;
    ext_a_next <= ext_a_reg;
    ext_b_next <= ext_b_reg;
    ext_c_next <= ext_c_reg;
    if reset_taken = '1' or timeout = '1' then
      ext_enable_next <= '0';
      ext_key_next <= '0';
    elsif WRITE_ENABLE = '1' and ADDR = "0111" then
      if DI = x"A5" and busy = '0' then
        ext_key_next <= '1';
      elsif DI = x"5A" and ext_key_reg = '1' and busy = '0' then
        ext_enable_next <= '1';
        ext_key_next <= '0';
      elsif DI = x"00" and busy = '0' then
        ext_enable_next <= '0';
        ext_key_next <= '0';
      else
        ext_key_next <= '0';
      end if;
    elsif chip_we = '1' then
      case chip_addr is
        when "01" => ext_a_next <= chip_wdata;
        when "10" => ext_b_next <= chip_wdata;
        when "11" => ext_c_next <= chip_wdata;
        when others => null;
      end case;
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

  -- a chip reset starts at the next chip clock after it is asked for, or when
  -- INT/RDY has been low for 255 internal clocks (commands take about 10)
  reset_taken <= reset_req_reg and tick;
  timeout     <= tick and to_sl(bus_reg = bus_wait and wait_reg = 255) and not intrdy;

  ---------------------------------------------------------------------------
  -- host writes go into the FIFO
  process (fifo_reg, wr_ptr_reg, rd_ptr_reg, count_reg, full, individual_reg, reset_req_reg,
           WRITE_ENABLE, ADDR, DI, bus_reg, up_reg, tick, reset_taken, timeout,
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
    if bus_reg = bus_idle and count_reg /= 0 and up_reg = '1' and reset_req_reg = '0' then
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
  -- chip register port
  --   idle:   pop a write and give it to the chip at once (one clk). A, B, C: done.
  --           A command: wait for INT/RDY (it goes low as the command is written).
  --   wait:   INT/RDY high again: done, or after a read command read B, then C
  process (bus_reg, wait_reg, cur_reg, resetn_reg, up_reg, rstcnt_reg, shadow_b_reg, shadow_c_reg,
           fifo_reg, rd_ptr_reg, count_reg, reset_req_reg, tick, reset_taken, timeout, intrdy,
           rdata, ext_enable_reg, ext_ack)
    variable rd_cmd : boolean;
  begin
    bus_next      <= bus_reg;
    wait_next     <= wait_reg;
    cur_next      <= cur_reg;
    resetn_next   <= resetn_reg;
    up_next       <= up_reg;
    rstcnt_next   <= rstcnt_reg;
    shadow_b_next <= shadow_b_reg;
    shadow_c_next <= shadow_c_reg;
    chip_we       <= '0';
    chip_addr     <= cur_reg(9 downto 8);
    chip_wdata    <= fifo_reg(to_integer(rd_ptr_reg))(7 downto 0);

    -- the command just written reads something back: $18-$1F frequency, $C0-$FF amplitude
    rd_cmd := cur_reg(9 downto 8) = "00" and
              (cur_reg(7 downto 3) = "00011" or cur_reg(7 downto 6) = "11");

    if reset_taken = '1' or timeout = '1' then
      -- chip reset: 8 internal clocks (the spec asks for at least 10 CLOCK periods = 5)
      resetn_next <= '0';
      up_next     <= '0';
      rstcnt_next <= to_unsigned(8, 4);
      bus_next    <= bus_idle;
    else
      if tick = '1' then
        -- chip in reset until the count runs out (4 internal clocks after power up). The
        -- core registers its reset, so it takes writes from the chip clock after that.
        up_next <= resetn_reg;
        if rstcnt_reg = 0 then
          resetn_next <= '1';
        else
          resetn_next <= '0';
          rstcnt_next <= rstcnt_reg - 1;
        end if;
      end if;

      case bus_reg is
        when bus_idle =>
          if count_reg /= 0 and up_reg = '1' and reset_req_reg = '0' then
            cur_next  <= fifo_reg(to_integer(rd_ptr_reg));
            chip_addr <= fifo_reg(to_integer(rd_ptr_reg))(9 downto 8);
            if ext_enable_reg = '1' and
               fifo_reg(to_integer(rd_ptr_reg))(9 downto 8) = "00" and
               ((unsigned(fifo_reg(to_integer(rd_ptr_reg))(7 downto 0)) >= to_unsigned(16#34#, 8) and
                 unsigned(fifo_reg(to_integer(rd_ptr_reg))(7 downto 0)) <= to_unsigned(16#36#, 8)) or
                fifo_reg(to_integer(rd_ptr_reg))(7 downto 0) = x"39") then
              -- Extension command completes locally at this clock. The following
              -- harmonic-RAM write is performed in this chip clock's spare edges.
              chip_we <= '0';
              if fifo_reg(to_integer(rd_ptr_reg))(7 downto 0) /= x"39" then
                bus_next <= bus_ext_wait;
              end if;
            else
              chip_we <= '1';
              if fifo_reg(to_integer(rd_ptr_reg))(9 downto 8) = "00" then
                wait_next <= (others => '0');
                bus_next  <= bus_wait;
              end if;
            end if;
          end if;
        when bus_ext_wait =>
          if ext_ack = '1' then
            bus_next <= bus_idle;
          end if;
        when bus_wait =>
          if tick = '1' and wait_reg /= 255 then
            wait_next <= wait_reg + 1;
          end if;
          if intrdy = '1' then
            if rd_cmd then
              bus_next <= bus_rd_b;
            else
              bus_next <= bus_idle;
            end if;
          end if;
        when bus_rd_b =>
          chip_addr     <= "10";
          shadow_b_next <= rdata;
          bus_next      <= bus_rd_c;
        when bus_rd_c =>
          chip_addr     <= "11";
          shadow_c_next <= rdata;
          bus_next      <= bus_idle;
      end case;
    end if;
  end process;

  ext_command <= '1' when ext_enable_reg = '1' and bus_reg = bus_idle and
    count_reg /= 0 and up_reg = '1' and reset_req_reg = '0' and
    fifo_reg(to_integer(rd_ptr_reg))(9 downto 8) = "00" and
    ((unsigned(fifo_reg(to_integer(rd_ptr_reg))(7 downto 0)) >= to_unsigned(16#34#, 8) and
      unsigned(fifo_reg(to_integer(rd_ptr_reg))(7 downto 0)) <= to_unsigned(16#36#, 8)) or
     fifo_reg(to_integer(rd_ptr_reg))(7 downto 0) = x"39") else '0';
  ext_we <= ext_command when fifo_reg(to_integer(rd_ptr_reg))(7 downto 0) = x"34" or
                             fifo_reg(to_integer(rd_ptr_reg))(7 downto 0) = x"35" or
                             fifo_reg(to_integer(rd_ptr_reg))(7 downto 0) = x"36" else '0';
  ext_kind <= "00" when fifo_reg(to_integer(rd_ptr_reg))(7 downto 0) = x"34" else
              "01" when fifo_reg(to_integer(rd_ptr_reg))(7 downto 0) = x"35" else "10";
  ext_index <= ext_a_reg(5 downto 0);
  ext_value <= ext_c_reg;
  ext_clear <= reset_taken or timeout or
      (WRITE_ENABLE and to_sl(ADDR = "0111") and to_sl(DI = x"00") and not busy) or
      (ext_command and to_sl(fifo_reg(to_integer(rd_ptr_reg))(7 downto 0) = x"39"));

  chip_reset <= not resetn_reg;

  -- status / read-back
  busy <= '0' when count_reg = 0 and bus_reg = bus_idle and loaded_reg = '1'
                   and up_reg = '1' and reset_req_reg = '0' else '1';
  -- Rev C extension control: writes at $D2C7 enable/disable extensions; reads remain status.
  with ADDR select DO <=
    shadow_b_reg           when "0010",
    shadow_c_reg           when "0011",
    voice_l_reg            when "0100",
    voice_r_reg            when "0101",
    volume_reg             when "0110",
    busy & full & "000000" when "0111",
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
    ce           => tick,
    reset        => chip_reset,
    ext_enable   => ext_enable_reg,
    ext_we       => ext_we,
    ext_kind     => ext_kind,
    ext_index    => ext_index,
    ext_value    => ext_value,
    ext_clear    => ext_clear,
    ext_ack      => ext_ack,
    addr         => chip_addr,
    we           => chip_we,
    wdata        => chip_wdata,
    rdata        => rdata,
    rdy          => intrdy,
    sample       => sample,
    sample_stb   => sample_stb,
    sample_v0    => v0,
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
  -- output: take each new sample (sample_stb, at the end of its chip clock).
  --   SUM mode:        one sample per period, on both channels
  --   INDIVIDUAL mode: one sample per voice; V0 marks voice 0. The previous
  --                    period's left/right sums are output when voice 0 arrives.
  process (voice_reg, acc_l_reg, acc_r_reg, out_l_reg, out_r_reg, individual_reg, resetn_reg,
           tick, sample_stb, v0, sample, voice_l_reg, voice_r_reg)
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
    elsif tick = '1' and sample_stb = '1' then
      s := resize(sample(15 downto 0), 20);
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
  DBG_SAMP      <= std_logic_vector(sample(15 downto 0));
  DBG_OUTSTBN   <= not sample_stb;
  DBG_V0        <= v0;
end architecture;
