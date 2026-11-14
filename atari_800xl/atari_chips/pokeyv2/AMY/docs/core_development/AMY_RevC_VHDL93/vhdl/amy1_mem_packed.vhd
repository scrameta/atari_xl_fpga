---------------------------------------------------------------------------
-- AMY1 memories, packed for the FPGA: 4 block RAMs (M9K), nothing in logic.
--
--   M9K 1, true dual port 512 x 18: SROMBS (256 x 17) on port A,
--                                    XROMBS (128 x 15) at word 256 on port B
--   M9K 2, true dual port 1024 x 5:  SROMINT (512 x 5) on port A,
--                                    XROMINT (128 x 5) at word 512 on port B,
--                                    NOISE (64 x 3) at word 640
--   M9K 3, simple dual port 256 x 36: HARMBRKPOINT | HARMCURNTVAL | LHPRAM in words
--                                    0..63, PHASERAM (8 x 20) in words 64..71, Rev C
--                                    coefficients in 72..119; words 128..255 belong to
--                                    the aux2 port (the note engine's extension page)
--   M9K 4, simple dual port 256 x 36: VOICE18 | VOICE3 in words 0..15; words
--                                    16..255 belong to the aux port (amy1_top's
--                                    note engine)
--   OCTSPL is no longer read.
--
-- The contract (amy1_core): the address of a chip clock gives its data before the ce
-- that ends the clock; a write enabled in a chip clock happens at that ce. Here, with
-- e1 and e2 the first and second clk edges after a ce:
--   e1   every block RAM port takes the core's read address (registered address,
--        unregistered output: the data is there for the rest of the chip clock);
--        M9K 3 writes the previous chip clock's PHASERAM word
--   e2   M9K 2 port B reads the NOISE row (XROMINT's data is held from e2 on);
--        M9K 3 reads the PHASERAM word (the harmonic word is held);
--        M9K 4's read port is free for the aux port (the voice data is held)
--   ce   the writes: NOISE on M9K 2 port A, the harmonic and voice words on the write
--        ports of M9K 3 and 4, merged with this clock's read of the same word (the
--        RAMs that share an address are one word)
-- So ce must be low on the two clks before each ce (three clks per chip clock at least).
-- Every read is registered (a read on the edge of a write to the same word returns the
-- old data, which the M9K does natively), so Quartus adds no pass-through logic.
--
-- The ROM tables and RAM power-up values come through the load port (image words as
-- laid out in amy1_mem_pkg) while the chip is stopped.
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.amy1_mem_pkg.all;

architecture packed of amy1_mem is
  -- which unit of the load image an address belongs to
  function in_unit(a : std_logic_vector(10 downto 0); base : natural; aw : natural) return boolean is
  begin
    return to_integer(unsigned(a)) >= base and to_integer(unsigned(a)) < base + 2 ** aw;
  end function;

  function offset(a : std_logic_vector(10 downto 0); base : natural) return natural is
  begin
    return to_integer(unsigned(a)) - base;
  end function;

  -- the clks after a ce: e1 (ce_d1 high before it), e2 (ce_d2 high before it)
  signal ce_d1, ce_d2, ce_d3, ce_d4, ce_d5, ce_d6, ce_d7, ce_d8 : std_logic := '0';

  -- M9K 1 and 2
  signal rom_a_qa, rom_a_qb : std_logic_vector(17 downto 0);
  signal rom_b_qa, rom_b_qb : std_logic_vector(4 downto 0);
  signal rom_a_we, rom_b_we : std_logic;
  signal rom_a_en : std_logic;
  signal rom_a_addr : natural range 0 to 511;
  signal rom_b_addr : natural range 0 to 1023;
  signal rom_a_data : std_logic_vector(17 downto 0);
  signal rom_b_data : std_logic_vector(4 downto 0);
  signal rom_b_addr_b : std_logic_vector(9 downto 0);
  signal xromint_hold : std_logic_vector(4 downto 0) := (others => '0');

  -- M9K3 is 128 x 36 (one block). The first 64 words are the original
  -- 30-bit harmonic state + 6 detuning bits. Unused addresses hold Rev C data:
  --  64..71 voice phases (historical), 72..87 4 x 6-bit stochasticity,
  --  88..119 2 x 18-bit accumulated phase offsets, 120..127 unused.
  type harm_t is array (0 to 255) of std_logic_vector(35 downto 0);
  type voice_t is array (0 to 255) of std_logic_vector(35 downto 0);
  signal harm : harm_t;
  signal voice : voice_t;
  signal harm_rd : std_logic_vector(35 downto 0);
  signal harm_hold : std_logic_vector(35 downto 0) := (others => '0');
  signal harm_q : std_logic_vector(35 downto 0);
  signal phase_hold : std_logic_vector(19 downto 0) := (others => '0');
  signal detune_hold_reg, detune_hold_next : std_logic_vector(5 downto 0) := (others => '0');
  signal stoch_hold_reg, stoch_hold_next : std_logic_vector(5 downto 0) := (others => '0');
  signal off_new_reg, off_new_next : std_logic_vector(17 downto 0) := (others => '0');
  signal phase_we_d : std_logic := '0';
  signal phase_addr_d : std_logic_vector(2 downto 0) := (others => '0');
  signal phase_data_d : std_logic_vector(19 downto 0) := (others => '0');
  signal det_valid_reg, det_valid_next : std_logic_vector(63 downto 0) := (others => '0');
  signal stoch_valid_reg, stoch_valid_next : std_logic_vector(63 downto 0) := (others => '0');
  signal off_valid_reg, off_valid_next : std_logic_vector(63 downto 0) := (others => '0');
  signal ext_req_reg, ext_req_next : std_logic := '0';
  signal ext_pending_reg, ext_pending_next : std_logic := '0';
  signal ext_ack_reg, ext_ack_next : std_logic := '0';
  signal ext_kind_reg, ext_kind_next : std_logic_vector(1 downto 0) := "00";
  signal ext_index_reg, ext_index_next : std_logic_vector(5 downto 0) := (others => '0');
  signal ext_value_reg, ext_value_next : std_logic_vector(7 downto 0) := (others => '0');
  signal ext_rd_addr, offset_addr, stochastic_addr : std_logic_vector(6 downto 0);

  signal voice_rd : std_logic_vector(35 downto 0);
  signal voice_hold : std_logic_vector(20 downto 0) := (others => '0');
  signal voice_q : std_logic_vector(20 downto 0);
  signal aux_rack_i, aux_wack_i, voice_wr : std_logic;
  signal harm_we, harm_re, voice_we, voice_re : std_logic;
  signal harm_waddr, harm_raddr   : std_logic_vector(7 downto 0);
  signal aux2_rack_i, aux2_wack_i : std_logic;
  signal harm_wdata               : std_logic_vector(35 downto 0);
  signal voice_waddr, voice_raddr : std_logic_vector(7 downto 0);
  signal voice_wdata              : std_logic_vector(35 downto 0);

begin

  process (clk)
  begin
    if rising_edge(clk) then
      ce_d1 <= ce;
      ce_d2 <= ce_d1;
      ce_d3 <= ce_d2;
      ce_d4 <= ce_d3;
      ce_d5 <= ce_d4;
      ce_d6 <= ce_d5;
      ce_d7 <= ce_d6;
      ce_d8 <= ce_d7;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- M9K 1: SROMBS (port A, words 0..255), XROMBS (port B, words 256..383), read at e1;
  -- port A also takes the image while loading
  rom_a_p: process (load_we, load_addr, load_data, srombs_addr)
  begin
    rom_a_we   <= '0';
    rom_a_addr <= to_integer(unsigned(srombs_addr));
    rom_a_data <= "0" & load_data(16 downto 0);
    if load_we = '1' and in_unit(load_addr, SROMBS_BASE, 8) then
      rom_a_we   <= '1';
      rom_a_addr <= offset(load_addr, SROMBS_BASE);
    elsif load_we = '1' and in_unit(load_addr, XROMBS_BASE, 7) then
      rom_a_we   <= '1';
      rom_a_addr <= 256 + offset(load_addr, XROMBS_BASE);
      rom_a_data <= "000" & load_data(14 downto 0);
    end if;
  end process;
  rom_a_en <= ce_d1 or load_we;

  rom_a: entity work.amy1_dpram
    generic map (AW => 9, DW => 18)
    port map (clk => clk, en => rom_a_en, we_a => rom_a_we,
              addr_a => std_logic_vector(to_unsigned(rom_a_addr, 9)), data_a => rom_a_data, q_a => rom_a_qa,
              addr_b => "10" & xrombs_addr, q_b => rom_a_qb);

  srombs_q <= rom_a_qa(16 downto 0);
  xrombs_q <= rom_a_qb(14 downto 0);

  ---------------------------------------------------------------------------
  -- M9K 2: SROMINT (port A, words 0..511) and XROMINT (port B, words 512..639) read at
  -- e1; NOISE (words 640..703) read on port B at e2, written on port A at the ce
  rom_b_p: process (load_we, load_addr, load_data, sromint_addr, ce, noise_we, noise_addr,
                    noise_wdata)
  begin
    rom_b_we   <= '0';
    rom_b_data <= load_data(4 downto 0);
    rom_b_addr <= to_integer(unsigned(sromint_addr));
    if load_we = '1' and in_unit(load_addr, SROMINT_BASE, 9) then
      rom_b_we   <= '1';
      rom_b_addr <= offset(load_addr, SROMINT_BASE);
    elsif load_we = '1' and in_unit(load_addr, XROMINT_BASE, 7) then
      rom_b_we   <= '1';
      rom_b_addr <= 512 + offset(load_addr, XROMINT_BASE);
    elsif load_we = '1' and in_unit(load_addr, NOISE_BASE, 6) then
      rom_b_we   <= '1';
      rom_b_addr <= 640 + offset(load_addr, NOISE_BASE);
      rom_b_data <= "00" & load_data(2 downto 0);
    elsif ce = '1' and noise_we = '1' then
      rom_b_we   <= '1';
      rom_b_addr <= 640 + to_integer(unsigned(noise_addr));
      rom_b_data <= "00" & noise_wdata;
    end if;
  end process;

  rom_b_addr_b <= "100" & xromint_addr when ce_d1 = '1' else "1010" & noise_addr;

  rom_b: entity work.amy1_dpram
    generic map (AW => 10, DW => 5)
    port map (clk => clk, en => '1', we_a => rom_b_we,
              addr_a => std_logic_vector(to_unsigned(rom_b_addr, 10)), data_a => rom_b_data, q_a => rom_b_qa,
              addr_b => rom_b_addr_b, q_b => rom_b_qb);
  -- (both ports read on every clk; their addresses only change after ce and at e2)

  process (clk)
  begin
    if rising_edge(clk) then
      if ce_d2 = '1' then                  -- port B moves on to NOISE at this edge
        xromint_hold <= rom_b_qb;
      end if;
    end if;
  end process;

  sromint_q <= rom_b_qa;
  xromint_q <= rom_b_qb when ce_d2 = '1' else xromint_hold;
  noise_q   <= rom_b_qb(2 downto 0);

  ---------------------------------------------------------------------------
  -- M9K 3: harmonic RAM / phase RAM / extra coefficients / phase offsets.
  -- Clock scheduling at 8.192 MHz: 14 system CLK edges per internal chip ce.
  -- e1 harmonic read + previous phase write
  -- e2 phase read
  -- e3 capture phase, read the *audio* harmonic detuning word
  -- e4 capture detune, read stochasticity word
  -- e5 capture stochasticity, read offset state word
  -- e6 calculate, write & capture updated phase offset
  -- e7 read pending extension-command coefficient word
  -- e8 RMW extension-command word and acknowledge (if pending)
  -- No extra M9K or read/write ports. THIS REQUIRES >=9 CLK CYCLES PER CE.
  stochastic_addr <= std_logic_vector(to_unsigned(72 +
    to_integer(unsigned(phase_slot(5 downto 2))), 7));
  offset_addr <= std_logic_vector(to_unsigned(88 +
    to_integer(unsigned(phase_slot(5 downto 1))), 7));
  ext_rd_addr <= '0' & ext_index_reg when ext_kind_reg = "01" else
    std_logic_vector(to_unsigned(72 + to_integer(unsigned(ext_index_reg(5 downto 2))), 7));

  harm_wr_p: process(load_we, load_addr, load_data, ce,
                     lhpram_we, harmcurntval_we, harmbrkpoint_we,
                     harm_hold, harmbrkpoint_wdata, harmcurntval_wdata,
                     lhpram_wdata, harmbrkpoint_addr, phase_we_d,
                     phase_addr_d, phase_data_d, ce_d6, ext_enable, offset_step,
                     harm_rd, phase_slot, offset_wdata, offset_addr,
                     ce_d8, ext_req_reg, ext_kind_reg, ext_value_reg,
                     ext_index_reg, ext_rd_addr, aux2_we, aux2_waddr, aux2_wdata)
    variable w : std_logic_vector(35 downto 0);
    variable n : natural range 0 to 3;
  begin
    harm_we <= '0';
    harm_waddr <= "00" & harmbrkpoint_addr;
    aux2_wack_i <= '0';
    harm_wdata <= (35 downto 20 => '0') & phase_data_d;
    w := (others => '0');
    if load_we = '1' and in_unit(load_addr, HARM_BASE, 6) then
      harm_we <= '1';
      harm_waddr <= "00" & load_addr(5 downto 0);
      harm_wdata <= (35 downto 30 => '0') & load_data(29 downto 0);
    elsif load_we = '1' and in_unit(load_addr, PHASERAM_BASE, 3) then
      harm_we <= '1';
      harm_waddr <= "01000" & load_addr(2 downto 0);
      harm_wdata <= (35 downto 20 => '0') & load_data(19 downto 0);
    elsif ce = '1' and (lhpram_we = '1' or harmcurntval_we = '1' or harmbrkpoint_we = '1') then
      w := harm_hold;
      if harmbrkpoint_we = '1' then w(15 downto 0) := harmbrkpoint_wdata; end if;
      if harmcurntval_we = '1' then w(28 downto 16) := harmcurntval_wdata; end if;
      if lhpram_we = '1' then w(29) := lhpram_wdata(0); end if;
      harm_we <= '1'; harm_wdata <= w;
    elsif phase_we_d = '1' then
      harm_we <= '1'; harm_waddr <= "01000" & phase_addr_d;
    elsif ce_d6 = '1' and ext_enable = '1' and offset_step = '1' then
      w := harm_rd;
      if phase_slot(0) = '0' then
        w(17 downto 0) := offset_wdata;
      else
        w(35 downto 18) := offset_wdata;
      end if;
      harm_we <= '1'; harm_waddr <= '0' & offset_addr; harm_wdata <= w;
    elsif ce_d8 = '1' and ext_req_reg = '1' then
      w := harm_rd;
      if ext_kind_reg = "01" then
        w(35 downto 30) := ext_value_reg(5 downto 0);
      else
        n := to_integer(unsigned(ext_index_reg(1 downto 0)));
        w(n*6+5 downto n*6) := ext_value_reg(5 downto 0);
      end if;
      harm_we <= '1'; harm_waddr <= '0' & ext_rd_addr; harm_wdata <= w;
    elsif aux2_we = '1' then
      -- lowest priority: the extension page (words 128..255) is never part of a
      -- core read-modify-write, so the write needs only a free port
      harm_we <= '1'; harm_waddr <= '1' & aux2_waddr; harm_wdata <= aux2_wdata;
      aux2_wack_i <= '1';
    end if;
  end process;

  harm_raddr <= "00" & harmbrkpoint_addr when ce_d1 = '1' else
                "01000" & phaseram_addr when ce_d2 = '1' else
                "00" & phase_slot when ce_d3 = '1' else
                '0' & stochastic_addr when ce_d4 = '1' else
                '0' & offset_addr when ce_d5 = '1' else
                '1' & aux2_raddr when aux2_rack_i = '1' else
                '0' & ext_rd_addr;
  harm_re <= ce_d1 or ce_d2 or ce_d3 or ce_d4 or ce_d5 or
             (ce_d7 and ext_req_reg) or aux2_rack_i;

  -- aux2 reads take any clock in which the core neither reads M9K 3 nor uses harm_rd in
  -- the next clock: the core reads at e1..e5 and e7 and uses each result one clock
  -- later (e2..e6, e8).  With at least 9 clocks per chip clock (the Rev C minimum)
  -- that leaves ce, e6 and e8..; at 3/7 of 57.344 MHz (14 clocks) eight per chip clock.
  aux2_rack_i <= aux2_re and not (ce_d1 or ce_d2 or ce_d3 or ce_d4 or ce_d5 or ce_d7)
                 and not load_we;
  aux2_rack  <= aux2_rack_i;
  aux2_wack  <= aux2_wack_i;
  aux2_rdata <= harm_rd;

  harm_ram: process(clk)
  begin
    if rising_edge(clk) then
      if harm_we = '1' then
        harm(to_integer(unsigned(harm_waddr))) <= harm_wdata;
      end if;
      if harm_re = '1' then
        harm_rd <= harm(to_integer(unsigned(harm_raddr)));
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- All extension control state is explicit *_reg / *_next, so the clocked
  -- process only copies next values. The RAM array itself stays synchronous
  -- and separate to preserve M9K inference.
  ext_state_regs: process(clk)
  begin
    if rising_edge(clk) then
      det_valid_reg <= det_valid_next;
      stoch_valid_reg <= stoch_valid_next;
      off_valid_reg <= off_valid_next;
      ext_req_reg <= ext_req_next;
      ext_pending_reg <= ext_pending_next;
      ext_ack_reg <= ext_ack_next;
      ext_kind_reg <= ext_kind_next;
      ext_index_reg <= ext_index_next;
      ext_value_reg <= ext_value_next;
      off_new_reg <= off_new_next;
      detune_hold_reg <= detune_hold_next;
      stoch_hold_reg <= stoch_hold_next;
      if ext_reset = '0' and ext_we = '1' and ext_kind /= "00" then
        assert ext_req_reg = '0' and ext_pending_reg = '0'
          report "extension RAM write overrun" severity failure;
      end if;
    end if;
  end process;

  ext_state_comb: process(ext_reset, ext_we, ext_kind, ext_index, ext_value,
                          ext_req_reg, ext_pending_reg, ext_ack_reg,
                          ext_kind_reg, ext_index_reg, ext_value_reg,
                          det_valid_reg, stoch_valid_reg, off_valid_reg,
                          detune_hold_reg, stoch_hold_reg, off_new_reg,
                          ce, ce_d4, ce_d5, ce_d6, ce_d8,
                          offset_step, offset_wdata, ext_enable, phase_slot,
                          harm_rd)
    variable h : natural range 0 to 63;
    variable n : natural range 0 to 3;
  begin
    det_valid_next <= det_valid_reg;
    stoch_valid_next <= stoch_valid_reg;
    off_valid_next <= off_valid_reg;
    ext_req_next <= ext_req_reg;
    ext_pending_next <= ext_pending_reg;
    ext_ack_next <= '0';
    ext_kind_next <= ext_kind_reg;
    ext_index_next <= ext_index_reg;
    ext_value_next <= ext_value_reg;
    off_new_next <= off_new_reg;
    detune_hold_next <= detune_hold_reg;
    stoch_hold_next <= stoch_hold_reg;
    if ext_reset = '1' then
      det_valid_next <= (others => '0');
      stoch_valid_next <= (others => '0');
      off_valid_next <= (others => '0');
      ext_req_next <= '0';
      ext_pending_next <= '0';
      ext_ack_next <= '0';
      off_new_next <= (others => '0');
    else
      if ext_we = '1' and ext_kind /= "00" then
        ext_pending_next <= '1';
        ext_kind_next <= ext_kind;
        ext_index_next <= ext_index;
        ext_value_next <= ext_value;
      end if;
      -- Arm on a complete chip-clock boundary, not between e7 and e8.
      if ce = '1' and ext_pending_reg = '1' then
        ext_req_next <= '1';
        ext_pending_next <= '0';
      end if;
      if ce_d6 = '1' and offset_step = '1' then
        if ext_enable = '1' then
          off_new_next <= offset_wdata;
          off_valid_next(to_integer(unsigned(phase_slot))) <= '1';
        else
          off_new_next <= (others => '0');
        end if;
      end if;
      if ce_d8 = '1' and ext_req_reg = '1' then
        h := to_integer(unsigned(ext_index_reg));
        if ext_kind_reg = "01" then
          det_valid_next(h) <= '1';
        else
          stoch_valid_next(h) <= '1';
        end if;
        ext_req_next <= '0';
        ext_ack_next <= '1';
      end if;
    end if;
    if ce_d4 = '1' then
      detune_hold_next <= harm_rd(35 downto 30);
    end if;
    if ce_d5 = '1' then
      n := to_integer(unsigned(phase_slot(1 downto 0)));
      stoch_hold_next <= harm_rd(n*6+5 downto n*6);
    end if;
  end process;

  -- Legacy RAM/phase hold registers remain simple clock-enabled pipelines.
  harm_hold_regs: process(clk)
  begin
    if rising_edge(clk) then
      if ce_d2 = '1' then
        harm_hold <= harm_rd;
      elsif ce_d8 = '1' and ext_req_reg = '1' and ext_kind_reg = "01" and
            ext_rd_addr = '0' & harmbrkpoint_addr then
        -- the core's read-modify-write at the coming ce merges harm_hold (read at
        -- e1, before this e8 detune write): forward the new detune so it is not undone
        harm_hold(35 downto 30) <= ext_value_reg(5 downto 0);
      end if;
      if ce_d3 = '1' then phase_hold <= harm_rd(19 downto 0); end if;
      phase_we_d <= ce and phaseram_we;
      if ce = '1' then
        phase_addr_d <= phaseram_addr;
        phase_data_d <= phaseram_wdata;
      end if;
    end if;
  end process;

  harm_q <= harm_rd when ce_d2 = '1' else harm_hold;
  harmbrkpoint_q <= harm_q(15 downto 0);
  harmcurntval_q <= harm_q(28 downto 16);
  lhpram_q <= harm_q(29 downto 29);
  phaseram_q <= phase_hold;

  detune_q <= detune_hold_reg when det_valid_reg(to_integer(unsigned(phase_slot))) = '1' else (others => '0');
  stoch_q <= stoch_hold_reg when stoch_valid_reg(to_integer(unsigned(phase_slot))) = '1' else (others => '0');
  offset_old_q <= (others => '0') when off_valid_reg(to_integer(unsigned(phase_slot))) = '0' else
                  harm_rd(17 downto 0) when phase_slot(0) = '0' else
                  harm_rd(35 downto 18);
  offset_new_q <= off_new_reg;
  ext_ack <= ext_ack_reg;

  ---------------------------------------------------------------------------
  -- M9K 4: voice RAMs, one word per voice: 20..18 VOICE3 | 17..0 VOICE18; the aux port
  -- reads when the core does not (its data is held from e2), writes when it does not
  voice_wr <= ce and (voice18_we or voice3_we);

  voice_wr_p: process (load_we, load_addr, load_data, voice_wr, voice_q, voice18_we, voice3_we,
                       voice18_wdata, voice3_wdata, voice18_addr, aux_wack_i, aux_waddr, aux_wdata)
    variable w : std_logic_vector(35 downto 0);
  begin
    voice_we    <= '0';
    voice_waddr <= aux_waddr;
    voice_wdata <= aux_wdata;
    if load_we = '1' and in_unit(load_addr, VOICE_BASE, 4) then
      voice_we    <= '1';
      voice_waddr <= "0000" & load_addr(3 downto 0);
      voice_wdata <= (35 downto 21 => '0') & load_data(20 downto 0);
    elsif voice_wr = '1' then
      w := (35 downto 21 => '0') & voice_q;      -- this clock's read of the same word
      if voice18_we = '1' then w(17 downto 0)  := voice18_wdata; end if;
      if voice3_we = '1'  then w(20 downto 18) := voice3_wdata;  end if;
      voice_we    <= '1';
      voice_waddr <= "0000" & voice18_addr;
      voice_wdata <= w;
    elsif aux_wack_i = '1' then
      voice_we    <= '1';
    end if;
  end process;

  voice_raddr <= "0000" & voice18_addr when ce_d1 = '1' else aux_raddr;
  voice_re    <= ce_d1 or aux_rack_i;

  voice_ram: process (clk)
  begin
    if rising_edge(clk) then
      if voice_we = '1' then
        voice(to_integer(unsigned(voice_waddr))) <= voice_wdata;
      end if;
      if voice_re = '1' then
        voice_rd <= voice(to_integer(unsigned(voice_raddr)));
      end if;
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if ce_d2 = '1' then
        voice_hold <= voice_rd(20 downto 0);
      end if;
    end if;
  end process;

  voice_q  <= voice_rd(20 downto 0) when ce_d2 = '1' else voice_hold;
  voice18_q <= voice_q(17 downto 0);
  voice3_q  <= voice_q(20 downto 18);

  aux_rack_i <= aux_re and not ce_d1 and not load_we;
  aux_wack_i <= aux_we and not load_we and not voice_wr;
  aux_rack   <= aux_rack_i;
  aux_wack   <= aux_wack_i;
  aux_rdata  <= voice_rd;

  octspl_q <= (others => '0');
end architecture;
