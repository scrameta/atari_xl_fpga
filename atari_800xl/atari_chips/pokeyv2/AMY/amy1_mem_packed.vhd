---------------------------------------------------------------------------
-- AMY1 memories, packed for the FPGA: 4 block RAMs (M9K) plus 160 bits of logic.
--
--   M9K 1, true dual port 512 x 18: SROMBS (256 x 17) on port A,
--                                    XROMBS (128 x 15) at word 256 on port B
--   M9K 2, true dual port 1024 x 5:  SROMINT (512 x 5) on port A,
--                                    XROMINT (128 x 5) at word 512 on port B,
--                                    NOISE (64 x 3) at word 640
--   M9K 3, simple dual port 64 x 30: HARMBRKPOINT | HARMCURNTVAL | LHPRAM
--   M9K 4, simple dual port 256 x 36: VOICE18 | VOICE3 in words 0..15; words
--                                    16..255 belong to the aux port (amy1_top's
--                                    note engine)
--   logic: PHASERAM (8 x 20). OCTSPL is no longer read.
--
-- The contract (amy1_core): the address of a chip clock gives its data before the ce
-- that ends the clock; a write enabled in a chip clock happens at that ce. Here, with
-- e1 and e2 the first and second clk edges after a ce:
--   e1   every block RAM port takes the core's read address (registered address,
--        unregistered output: the data is there for the rest of the chip clock)
--   e2   M9K 2 port B reads the NOISE row (XROMINT's data is held from e2 on);
--        M9K 4's read port is free for the aux port (the voice data is held)
--   ce   the writes: NOISE on M9K 2 port A, the harmonic and voice words on the write
--        ports of M9K 3 and 4, merged with this clock's read of the same word (the
--        RAMs that share an address are one word)
-- So ce must be low on the two clks before each ce (three clks per chip clock at least).
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
  signal ce_d1, ce_d2 : std_logic := '0';

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

  -- M9K 3 and 4
  type harm_t  is array (0 to 63) of std_logic_vector(29 downto 0);
  type voice_t is array (0 to 255) of std_logic_vector(35 downto 0);
  signal harm  : harm_t;
  signal voice : voice_t;
  signal harm_rd  : std_logic_vector(29 downto 0);
  signal voice_rd : std_logic_vector(35 downto 0);
  signal voice_hold : std_logic_vector(20 downto 0) := (others => '0');
  signal voice_q : std_logic_vector(20 downto 0);
  signal harm_raddr  : std_logic_vector(5 downto 0) := (others => '0');
  signal voice_raddr : std_logic_vector(7 downto 0) := (others => '0');
  signal aux_rack_i, aux_wack_i, voice_wr : std_logic;

  -- logic
  signal phaseram_mem : phaseram_t;
begin

  process (clk)
  begin
    if rising_edge(clk) then
      ce_d1 <= ce;
      ce_d2 <= ce_d1;
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
  -- M9K 3: harmonic RAMs, one word per harmonic:
  --   29 LHPRAM | 28..16 HARMCURNTVAL | 15..0 HARMBRKPOINT
  harm_ram: process (clk)
    variable w : std_logic_vector(29 downto 0);
  begin
    if rising_edge(clk) then
      if load_we = '1' and in_unit(load_addr, HARM_BASE, 6) then
        harm(offset(load_addr, HARM_BASE)) <= load_data(29 downto 0);
      elsif ce = '1' and (lhpram_we = '1' or harmcurntval_we = '1' or harmbrkpoint_we = '1') then
        w := harm_rd;                      -- this clock's read of the same word
        if harmbrkpoint_we = '1' then w(15 downto 0)  := harmbrkpoint_wdata; end if;
        if harmcurntval_we = '1' then w(28 downto 16) := harmcurntval_wdata; end if;
        if lhpram_we = '1'       then w(29)           := lhpram_wdata(0);    end if;
        harm(to_integer(unsigned(harmbrkpoint_addr))) <= w;
      end if;
      if ce_d1 = '1' then
        harm_raddr <= harmbrkpoint_addr;
      end if;
    end if;
  end process;

  harm_rd <= harm(to_integer(unsigned(harm_raddr)));
  harmbrkpoint_q <= harm_rd(15 downto 0);
  harmcurntval_q <= harm_rd(28 downto 16);
  lhpram_q       <= harm_rd(29 downto 29);

  ---------------------------------------------------------------------------
  -- M9K 4: voice RAMs, one word per voice: 20..18 VOICE3 | 17..0 VOICE18; the aux port
  -- reads when the core does not (its data is held from e2), writes when it does not
  voice_wr <= ce and (voice18_we or voice3_we);

  voice_ram: process (clk)
    variable w : std_logic_vector(35 downto 0);
  begin
    if rising_edge(clk) then
      if load_we = '1' and in_unit(load_addr, VOICE_BASE, 4) then
        voice(offset(load_addr, VOICE_BASE)) <= (35 downto 21 => '0') & load_data(20 downto 0);
      elsif voice_wr = '1' then
        w := (35 downto 21 => '0') & voice_q;    -- this clock's read of the same word
        if voice18_we = '1' then w(17 downto 0)  := voice18_wdata; end if;
        if voice3_we = '1'  then w(20 downto 18) := voice3_wdata;  end if;
        voice(to_integer(unsigned(voice18_addr))) <= w;
      elsif aux_wack_i = '1' then
        voice(to_integer(unsigned(aux_waddr))) <= aux_wdata;
      end if;
      if ce_d1 = '1' then
        voice_raddr <= "0000" & voice18_addr;
      elsif aux_rack_i = '1' then
        voice_raddr <= aux_raddr;
      end if;
      if ce_d2 = '1' then
        voice_hold <= voice_rd(20 downto 0);
      end if;
    end if;
  end process;

  voice_rd <= voice(to_integer(unsigned(voice_raddr)));
  voice_q  <= voice_rd(20 downto 0) when ce_d2 = '1' else voice_hold;
  voice18_q <= voice_q(17 downto 0);
  voice3_q  <= voice_q(20 downto 18);

  aux_rack_i <= aux_re and not ce_d1 and not load_we;
  aux_wack_i <= aux_we and not load_we and not voice_wr;
  aux_rack   <= aux_rack_i;
  aux_wack   <= aux_wack_i;
  aux_rdata  <= voice_rd;

  ---------------------------------------------------------------------------
  -- PHASERAM in logic
  phaseram_p: process (clk)
  begin
    if rising_edge(clk) then
      if load_we = '1' then
        if in_unit(load_addr, PHASERAM_BASE, 3) then
          phaseram_mem(offset(load_addr, PHASERAM_BASE)) <= load_data(19 downto 0);
        end if;
      elsif ce = '1' and phaseram_we = '1' then
        phaseram_mem(to_integer(unsigned(phaseram_addr))) <= phaseram_wdata;
      end if;
      phaseram_q <= phaseram_mem(to_integer(unsigned(phaseram_addr)));
    end if;
  end process;

  octspl_q <= (others => '0');
end architecture;
