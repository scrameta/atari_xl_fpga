---------------------------------------------------------------------------
-- AMY1 note engine (part of amy1_top, generic ENGINE)
--
-- The 6502 sends note events; the engine writes every harmonic breakpoint of
-- the voice into amy1_top's command FIFO, from instrument tables, so a VBI
-- player only needs a few stores per note.
--
-- Host registers (amy1_top ADDR 8..15):
--   8  W0      \  a word builder, kept between writes: the next event or
--   9  W1       > RAM word is {byte3, W2, W1, W0}
--   10 W2      /
--   11 EVENT   write byte3: queue the event {byte3, W2, W1, W0}
--                $90+v note on:  W0 note (semitones, 0 = the global word's
--                                note 0), W1 level (AMY 1/4 dB, $D8 normal),
--                                W2 harmonics to use (1..16, the band limit)
--                $80+v note off
--                $A0+v instrument W0 (0..11) for voice v; the voice must be
--                      silent (its ceiling becomes 0)
--   12 ADDR    RAM word address for WRITE (32..255)
--   13 WRITE   write byte3: RAM word ADDR <= {byte3, W2, W1, W0}, at once
--              (not queued: change what a queued event will read only when
--              STATUS says the engine is idle)
--   14 STATUS  read: bit 7 busy (queue not empty or working), bit 6 queue full
--              (16 events); an EVENT write while full is lost
--   15 CONFIG  bit 0 engine on, bit 1 8 harmonics x 8 voices (else 16 x 4);
--              reads back (8..14 read STATUS), so a player can find the engine
-- While the engine is busy its breakpoints are going into the chip's A/B/C
-- latches: the host writes chip registers 0..3 itself only while it is idle.
--
-- RAM (amy1_mem's VOICE block, aux port; 36-bit words):
--   0..15    the chip's VOICE RAM (not for us)
--   16..31   event queue
--   32..39   voice v state: 3..0 instrument, 4 released, 15..8 release time,
--            23..16 ceiling (no harmonic k is above ceiling - its level
--            offset), 30..24 note
--   40       global: 12..0 frequency word of note 0
--   48..59   instrument i header: 7..0 release slope, 15..8 glide slope up,
--            20..16 release drop per time unit (1/4 dB, rounded down, 0..31),
--            23 decay (plucked: decay breakpoints after the attack),
--            31..24 glide slope down
--   64..255  instrument i, harmonic k at word 64 + 16 i + k:
--            7..0 level offset (1/4 dB below the note level; 255 = unused),
--            15..8 attack slope (0 = jump), 23..16 decay slope,
--            31..24 sustain offset below the peak (255 = decay to 0)
-- Time unit: 2^UNIT_LOG2 chip internal clocks: 9.2 ms with 14 at 2 x PHI2, or
-- with 15 at 4 x PHI2 (the release drops in the headers are per unit).
--
-- Per note on, the engine writes: the frequency (gliding only when legato),
-- then for every harmonic of the voice either its attack breakpoint or, if it
-- is not part of the note, a release; then, for plucked instruments, the decay
-- breakpoints. A note off releases every harmonic. Every harmonic is written in
-- every pass, and the engine waits 1-2 samples after each pass, so a harmonic's
-- next breakpoint reaches the chip well after its jump has been applied (a jump is
-- lost if the next write to that harmonic comes before the harmonic's next slot,
-- up to ~1.3 samples later).
--
-- Slopes always point at their destination. Releases fall to 0, decays follow
-- jumps only, and an attack rises only when the note is at least 2 dB above
-- the voice's ceiling, else it jumps. The ceiling is the loudest level since
-- the voice was silent, less the instrument's release drop for every time unit
-- the voice has been released. (The release time has 8 bits: after 255 units
-- the drop can come out too small, so a voice may jump where it could have
-- risen, never the other way.)
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_engine is
  generic (
    GLIDE      : boolean := true;                    -- glide slopes (about 25 LEs)
    UNIT_LOG2  : natural := 14                       -- time unit: 14 at 2 x PHI2, 15 at 4 x PHI2
  );
  port (
    clk        : in  std_logic;
    reset_n    : in  std_logic;
    tick       : in  std_logic;                      -- one per chip internal clock

    -- host registers 8..15
    cpu_we     : in  std_logic;
    cpu_addr   : in  std_logic_vector(2 downto 0);
    cpu_di     : in  std_logic_vector(7 downto 0);
    cpu_do     : out std_logic_vector(7 downto 0);

    -- the VOICE block RAM's aux port
    aux_re     : out std_logic;
    aux_raddr  : out std_logic_vector(7 downto 0);
    aux_rack   : in  std_logic;
    aux_rdata  : in  std_logic_vector(35 downto 0);
    aux_we     : out std_logic;
    aux_waddr  : out std_logic_vector(7 downto 0);
    aux_wdata  : out std_logic_vector(35 downto 0);
    aux_wack   : in  std_logic;

    -- chip writes, into amy1_top's command FIFO
    push_req   : out std_logic;
    push_addr  : out std_logic_vector(1 downto 0);   -- 0 command, 1 A, 2 B, 3 C
    push_data  : out std_logic_vector(7 downto 0);
    push_ack   : in  std_logic
  );
end entity;

architecture vhdl of amy1_engine is
  type state_t is (st_idle, st_ev_req, st_ev_dat, st_vs_req, st_vs_dat, st_hd_req, st_hd_dat,
                   st_drop, st_gl_req, st_gl_dat, st_k_req, st_k_dat, st_push, st_next, st_wait, st_vs_write);
  signal state_reg, state_next : state_t := st_idle;

  -- host side
  signal w0_reg, w0_next, w1_reg, w1_next, w2_reg, w2_next : std_logic_vector(7 downto 0) := (others => '0');
  signal iaddr_reg, iaddr_next   : unsigned(7 downto 0) := (others => '0');
  signal config_reg, config_next : std_logic_vector(1 downto 0) := (others => '0');
  signal pw_reg, pw_next         : std_logic := '0';                      -- host RAM write pending
  signal pw_event_reg, pw_event_next : std_logic := '0';                  -- ... an event
  signal pw_b3_reg, pw_b3_next       : std_logic_vector(7 downto 0) := (others => '0');
  signal wr_ptr_reg, wr_ptr_next, rd_ptr_reg, rd_ptr_next : unsigned(4 downto 0) := (others => '0');

  -- time: units of 2^UNIT_LOG2 internal clocks
  signal pre_reg, pre_next : unsigned(UNIT_LOG2 - 1 downto 0) := (others => '0');
  signal now_reg, now_next : unsigned(7 downto 0) := (others => '0');

  -- the event being worked on
  signal op_reg, op_next       : std_logic_vector(1 downto 0) := (others => '0');  -- 01 on, 10 off
  signal voice_reg, voice_next : unsigned(2 downto 0) := (others => '0');
  signal note_reg, note_next   : unsigned(6 downto 0) := (others => '0');
  signal lvl_reg, lvl_next     : unsigned(7 downto 0) := (others => '0');
  signal hm_reg, hm_next       : unsigned(4 downto 0) := (others => '0');
  signal inst_reg, inst_next   : unsigned(3 downto 0) := (others => '0');
  signal legato_reg, legato_next   : std_logic := '0';   -- voice not released
  signal rise_reg, rise_next       : std_logic := '0';   -- attacks may rise
  signal up_reg, up_next           : std_logic := '0';   -- glide upwards
  signal x_reg, x_next             : signed(9 downto 0) := (others => '0');     -- level - ceiling + drop
  signal rel_reg, rel_next         : std_logic_vector(7 downto 0) := (others => '0');
  signal decay_reg, decay_next     : std_logic := '0';
  signal pass_reg, pass_next       : std_logic := '0';   -- 0 attack, 1 decay
  signal k_reg, k_next             : unsigned(3 downto 0) := (others => '0');

  -- the breakpoint being pushed: A, (B,) C, then the command
  signal pa_reg, pa_next, pc_reg, pc_next : std_logic_vector(7 downto 0) := (others => '0');
  signal pb_reg, pb_next   : std_logic_vector(4 downto 0) := (others => '0');
  signal freq_reg, freq_next : std_logic := '0';        -- the frequency (A, B, C), else a harmonic (A, C)
  signal ph_reg, ph_next   : unsigned(1 downto 0) := (others => '0');

  signal hpv8 : std_logic;
  signal count : unsigned(4 downto 0);
  signal queue_full, busy : std_logic;
  signal last_k : std_logic;
  signal eng_we : std_logic;                            -- engine RAM write (voice state)
  signal eng_wdata : std_logic_vector(35 downto 0);
begin
  hpv8 <= config_reg(1);
  count <= wr_ptr_reg - rd_ptr_reg;
  queue_full <= count(4);                           -- 16 events
  busy <= '0' when state_reg = st_idle and count = 0 and pw_reg = '0' else '1';
  last_k <= '1' when (hpv8 = '1' and k_reg(2 downto 0) = "111") or k_reg = "1111" else '0';

  process (clk, reset_n)
  begin
    if reset_n = '0' then
      state_reg  <= st_idle;
      config_reg <= (others => '0');
      pw_reg     <= '0';
      wr_ptr_reg <= (others => '0');
      rd_ptr_reg <= (others => '0');
    elsif rising_edge(clk) then
      state_reg <= state_next;
      w0_reg <= w0_next; w1_reg <= w1_next; w2_reg <= w2_next;
      iaddr_reg <= iaddr_next; config_reg <= config_next;
      pw_reg <= pw_next; pw_event_reg <= pw_event_next; pw_b3_reg <= pw_b3_next;
      wr_ptr_reg <= wr_ptr_next; rd_ptr_reg <= rd_ptr_next;
      pre_reg <= pre_next; now_reg <= now_next;
      op_reg <= op_next; voice_reg <= voice_next; note_reg <= note_next; lvl_reg <= lvl_next;
      hm_reg <= hm_next; inst_reg <= inst_next; legato_reg <= legato_next; rise_reg <= rise_next;
      up_reg <= up_next; x_reg <= x_next; rel_reg <= rel_next; decay_reg <= decay_next;
      pass_reg <= pass_next; k_reg <= k_next;
      pa_reg <= pa_next; pb_reg <= pb_next; pc_reg <= pc_next; freq_reg <= freq_next;
      ph_reg <= ph_next;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- time base
  process (pre_reg, now_reg, tick)
  begin
    pre_next <= pre_reg;
    now_next <= now_reg;
    if tick = '1' then
      pre_next <= pre_reg + 1;
      if pre_reg = (pre_reg'range => '1') then
        now_next <= now_reg + 1;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- host registers; a host RAM write waits for the port (the engine's own
  -- writes wait for it in turn)
  process (cpu_we, cpu_addr, cpu_di, w0_reg, w1_reg, w2_reg, iaddr_reg, config_reg,
           pw_reg, pw_event_reg, pw_b3_reg, wr_ptr_reg, queue_full, aux_wack)
  begin
    w0_next <= w0_reg; w1_next <= w1_reg; w2_next <= w2_reg;
    iaddr_next <= iaddr_reg; config_next <= config_reg;
    pw_next <= pw_reg; pw_event_next <= pw_event_reg; pw_b3_next <= pw_b3_reg;
    wr_ptr_next <= wr_ptr_reg;

    if pw_reg = '1' and aux_wack = '1' then
      pw_next <= '0';
      if pw_event_reg = '1' then
        wr_ptr_next <= wr_ptr_reg + 1;
      end if;
    end if;

    if cpu_we = '1' then
      case cpu_addr is
        when "000" => w0_next <= cpu_di;
        when "001" => w1_next <= cpu_di;
        when "010" => w2_next <= cpu_di;
        when "011" =>                               -- EVENT
          if queue_full = '0' and pw_reg = '0' then
            pw_next <= '1';
            pw_event_next <= '1';
            pw_b3_next <= cpu_di;
          end if;
        when "100" => iaddr_next <= unsigned(cpu_di);
        when "101" =>                               -- WRITE
          if pw_reg = '0' and iaddr_reg(7 downto 5) /= "000" then
            pw_next <= '1';
            pw_event_next <= '0';
            pw_b3_next <= cpu_di;
          end if;
        when "111" => config_next <= cpu_di(1 downto 0);
        when others => null;
      end case;
    end if;
  end process;

  -- CONFIG reads back (so a player can tell whether the engine is there), the rest read STATUS
  cpu_do <= "000000" & config_reg when cpu_addr = "111" else busy & queue_full & "000000";

  -- RAM writes: the host's first, then the engine's (voice state)
  aux_we    <= pw_reg or eng_we;
  aux_waddr <= "0001" & std_logic_vector(wr_ptr_reg(3 downto 0)) when pw_reg = '1' and pw_event_reg = '1' else
               std_logic_vector(iaddr_reg)                         when pw_reg = '1' else
               "00100" & std_logic_vector(voice_reg);
  aux_wdata <= "0000" & pw_b3_reg & w2_reg & w1_reg & w0_reg when pw_reg = '1' else eng_wdata;

  ---------------------------------------------------------------------------
  -- the engine
  process (state_reg, config_reg, count, pre_reg, rd_ptr_reg, aux_rack, aux_rdata, aux_wack, pw_reg, push_ack,
           now_reg, op_reg, voice_reg, note_reg, lvl_reg, hm_reg, inst_reg, legato_reg, rise_reg, up_reg, x_reg,
           rel_reg, decay_reg, pass_reg, k_reg, last_k, hpv8,
           pa_reg, pb_reg, pc_reg, freq_reg, ph_reg)
    variable f    : unsigned(12 downto 0);
    variable p    : unsigned(8 downto 0);
    variable s    : unsigned(8 downto 0);
    variable c    : unsigned(7 downto 0);
    variable inn  : boolean;                -- harmonic k is part of the note
    variable hidx : std_logic_vector(5 downto 0);
  begin
    state_next <= state_reg;
    rd_ptr_next <= rd_ptr_reg;
    op_next <= op_reg; voice_next <= voice_reg; note_next <= note_reg; lvl_next <= lvl_reg;
    hm_next <= hm_reg; inst_next <= inst_reg; legato_next <= legato_reg; rise_next <= rise_reg;
    up_next <= up_reg; x_next <= x_reg; rel_next <= rel_reg; decay_next <= decay_reg;
    pass_next <= pass_reg; k_next <= k_reg;
    pa_next <= pa_reg; pb_next <= pb_reg; pc_next <= pc_reg; freq_next <= freq_reg;
    ph_next <= ph_reg;

    aux_re <= '0';
    aux_raddr <= (others => '0');
    eng_we <= '0';
    eng_wdata <= (others => '0');
    push_req <= '0';
    push_addr <= "00";
    push_data <= (others => '0');

    -- harmonic number of voice/k
    if hpv8 = '1' then
      hidx := std_logic_vector(voice_reg) & std_logic_vector(k_reg(2 downto 0));
    else
      hidx := std_logic_vector(voice_reg(1 downto 0)) & std_logic_vector(k_reg);
    end if;

    case state_reg is
      when st_idle =>
        if config_reg(0) = '1' and count /= 0 then
          state_next <= st_ev_req;
        end if;

      -- the next event
      when st_ev_req =>
        aux_re <= '1';
        aux_raddr <= "0001" & std_logic_vector(rd_ptr_reg(3 downto 0));
        if aux_rack = '1' then
          state_next <= st_ev_dat;
        end if;
      when st_ev_dat =>
        rd_ptr_next <= rd_ptr_reg + 1;
        voice_next <= unsigned(aux_rdata(26 downto 24));
        note_next  <= unsigned(aux_rdata(6 downto 0));
        lvl_next   <= unsigned(aux_rdata(15 downto 8));
        hm_next    <= unsigned(aux_rdata(20 downto 16));
        inst_next  <= unsigned(aux_rdata(3 downto 0));
        case aux_rdata(31 downto 28) is
          when "1001" => op_next <= "01"; state_next <= st_vs_req;   -- note on
          when "1000" => op_next <= "10"; state_next <= st_vs_req;   -- note off
          when "1010" => op_next <= "00"; state_next <= st_vs_write; -- instrument
          when others => state_next <= st_idle;
        end case;

      -- voice state
      when st_vs_req =>
        aux_re <= '1';
        aux_raddr <= "00100" & std_logic_vector(voice_reg);
        if aux_rack = '1' then
          state_next <= st_vs_dat;
        end if;
      when st_vs_dat =>
        inst_next   <= unsigned(aux_rdata(3 downto 0));
        legato_next <= not aux_rdata(4);
        pa_next     <= std_logic_vector(now_reg - unsigned(aux_rdata(15 downto 8)));  -- age
        x_next      <= signed("00" & lvl_reg) - signed("00" & aux_rdata(23 downto 16));
        if note_reg > unsigned(aux_rdata(30 downto 24)) then
          up_next <= '1';
        else
          up_next <= '0';
        end if;
        state_next <= st_hd_req;

      -- instrument header
      when st_hd_req =>
        aux_re <= '1';
        aux_raddr <= "0011" & std_logic_vector(inst_reg);
        if aux_rack = '1' then
          state_next <= st_hd_dat;
        end if;
      when st_hd_dat =>
        rel_next   <= aux_rdata(7 downto 0);
        decay_next <= aux_rdata(23);
        pb_next    <= aux_rdata(20 downto 16);            -- release drop per unit
        -- glide only when legato, in the direction of the new note
        pc_next <= (others => '0');
        if GLIDE and legato_reg = '1' then
          if up_reg = '1' then
            pc_next <= aux_rdata(15 downto 8);
          else
            pc_next <= aux_rdata(31 downto 24);
          end if;
        end if;
        state_next <= st_drop;

      -- the ceiling falls by the drop for every unit since the release (age in
      -- pa): add the drop to x until the note is 2 dB above it (x >= 8)
      when st_drop =>
        if x_reg < 8 and legato_reg = '0' and pa_reg /= x"00" then
          x_next <= x_reg + signed("00000" & pb_reg);
          pa_next <= std_logic_vector(unsigned(pa_reg) - 1);
        else
          if x_reg >= 8 then
            rise_next <= '1';
          else
            rise_next <= '0';
          end if;
          k_next <= (others => '0');
          pass_next <= '0';
          if op_reg = "10" then
            state_next <= st_k_req;                      -- note off: every harmonic falls
          else
            state_next <= st_gl_req;
          end if;
        end if;


      -- frequency
      when st_gl_req =>
        aux_re <= '1';
        aux_raddr <= std_logic_vector(to_unsigned(40, 8));
        if aux_rack = '1' then
          state_next <= st_gl_dat;
        end if;
      when st_gl_dat =>
        f := unsigned(aux_rdata(12 downto 0)) + (note_reg & "000000");
        pa_next <= pc_reg;                               -- the glide slope
        pb_next <= std_logic_vector(f(12 downto 8));
        pc_next <= std_logic_vector(f(7 downto 0));
        freq_next <= '1';
        ph_next <= "00";
        state_next <= st_push;

      -- one harmonic: attack or release (pass 0), decay (pass 1)
      when st_k_req =>
        aux_re <= '1';
        aux_raddr <= std_logic_vector(inst_reg + 4) & std_logic_vector(k_reg);
        if aux_rack = '1' then
          state_next <= st_k_dat;
        end if;
      when st_k_dat =>
        p := ('0' & lvl_reg) - unsigned('0' & aux_rdata(7 downto 0));
        inn := op_reg = "01" and k_reg < hm_reg and aux_rdata(7 downto 0) /= x"FF" and p(8) = '0' and p(7 downto 0) /= 0;
        freq_next <= '0';
        ph_next <= "00";
        state_next <= st_push;
        if pass_reg = '0' then
          if inn then
            if rise_reg = '1' then
              pa_next <= aux_rdata(15 downto 8);         -- rise (or jump if 0)
            else
              pa_next <= (others => '0');                -- jump
            end if;
            pc_next <= std_logic_vector(p(7 downto 0));
          else
            pa_next <= rel_reg;                          -- not in this note (or note off): fall to 0
            pc_next <= (others => '0');
          end if;
        else
          -- decay, only after a jump
          if inn and (rise_reg = '0' or aux_rdata(15 downto 8) = x"00") then
            pa_next <= aux_rdata(23 downto 16);
            s := p - unsigned('0' & aux_rdata(31 downto 24));
            if s(8) = '1' then
              pc_next <= (others => '0');
            else
              pc_next <= std_logic_vector(s(7 downto 0));
            end if;
          else
            state_next <= st_next;                       -- nothing to write
          end if;
        end if;

      when st_next =>
        k_next <= k_reg + 1;
        if last_k = '0' then
          state_next <= st_k_req;
        else
          pa_next <= "000000" & '0' & pre_reg(7);
          state_next <= st_wait;
        end if;

      -- after a pass, wait for two changes of prescaler bit 7 (129-256 internal
      -- clocks, 1-2 samples; pa(0) holds the bit, pa(1) the first change): a jump
      -- written in the pass must reach its harmonic's slot before the next write to
      -- that harmonic, and 8 x 8 only puts 8 breakpoints (~1.2-1.5 samples) between
      when st_wait =>
        if pre_reg(7) /= pa_reg(0) then
          pa_next(0) <= pre_reg(7);
          pa_next(1) <= '1';
          if pa_reg(1) = '1' then
            if op_reg = "01" and pass_reg = '0' and decay_reg = '1' then
              k_next <= (others => '0');
              pass_next <= '1';
              state_next <= st_k_req;
            else
              state_next <= st_vs_write;
            end if;
          end if;
        end if;

      -- one breakpoint into the command FIFO: A, (B,) C, command
      when st_push =>
        push_req <= '1';
        case ph_reg is
          when "00" => push_addr <= "01"; push_data <= pa_reg;
          when "01" => push_addr <= "10"; push_data <= "000" & pb_reg;
          when "10" => push_addr <= "11"; push_data <= pc_reg;
          when others =>
            push_addr <= "00";
            if freq_reg = '1' then
              push_data <= "00001" & std_logic_vector(voice_reg);   -- frequency breakpoint
            else
              push_data <= "01" & hidx;                             -- amplitude breakpoint
            end if;
        end case;
        if push_ack = '1' then
          ph_next <= ph_reg + 1;
          if ph_reg = "00" and freq_reg = '0' then
            ph_next <= "10";
          end if;
          if ph_reg = "11" then
            if freq_reg = '1' then
              state_next <= st_k_req;
            else
              state_next <= st_next;
            end if;
          end if;
        end if;

      -- voice state: instrument, released (and when), ceiling, note. The
      -- ceiling now is level - x (the old one less the drop); after a note on,
      -- the louder of that and the note's level.
      when st_vs_write =>
        c := lvl_reg - unsigned(x_reg(7 downto 0));
        if op_reg = "01" and x_reg(9) = '0' then
          c := lvl_reg;
        end if;
        if pw_reg = '0' then
          eng_we <= '1';
          eng_wdata(3 downto 0) <= std_logic_vector(inst_reg);
          eng_wdata(30 downto 24) <= std_logic_vector(note_reg);
          eng_wdata(15 downto 8) <= std_logic_vector(now_reg);
          if op_reg = "01" then
            eng_wdata(4) <= '0';
            eng_wdata(23 downto 16) <= std_logic_vector(c);
          elsif op_reg = "10" then
            eng_wdata(4) <= '1';
            eng_wdata(23 downto 16) <= std_logic_vector(c);
          else
            eng_wdata(4) <= '1';                                -- new instrument: silent, ceiling 0
          end if;
          if aux_wack = '1' then
            state_next <= st_idle;
          end if;
        end if;
    end case;
  end process;
end architecture;
