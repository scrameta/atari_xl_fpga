---------------------------------------------------------------------------
-- AMY1 memories, packed for the FPGA: 4 block RAMs (M9K) plus 160 bits of logic.
--
--   M9K 1, true dual port 512 x 18: SROMBS (256 x 17) on port A,
--                                    XROMBS (128 x 15) at word 256 on port B
--   M9K 2, true dual port 1024 x 5:  SROMINT (512 x 5) on port A,
--                                    XROMINT (128 x 5) at word 512 on port B,
--                                    NOISE (64 x 3) at word 640 (see below)
--   M9K 3, simple dual port 64 x 30: HARMBRKPOINT | HARMCURNTVAL | LHPRAM
--   M9K 4, simple dual port 256 x 36: VOICE18 | VOICE3 in words 0..15; words
--                                    16..255 belong to the aux port (amy1_top's
--                                    note engine), which uses the RAM's ports on
--                                    clocks the chip does not need them
--   logic: PHASERAM (8 x 20) RAM, OCTSPL (32 x 4) a constant table (LUTs)
--
-- Every chip address changes in step 1, so every M9K port reads at that step.
-- The NOISE RAM therefore uses M9K 2 in the clock after each step instead:
-- port B reads it and port A does the step's write, at the same edge (port B
-- gets the old data, as the reference read-before-write). Its data is ready
-- one clock after the step, so the core has one clock less to use it before
-- the next step (one clock at 2 steps per 2 clocks). The ROMs read at the step
-- as before and are held while the ports do this.
--
-- Same behaviour as the reference layout (architecture rtl): the address of step k
-- reads data for step k+1, and a write in step k is seen from step k+2 on. RAMs that
-- share an address are one word. Their writes are done one clock after the step
-- (the fields not being written come from that step's read of the same word),
-- so step_en must never be high on two clocks in a row.
--
-- The ROM tables and RAM power-up values come through the load port (image words
-- as laid out in amy1_mem_pkg) while the chip is stopped.
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

  ---------------------------------------------------------------------------
  -- M9K 1 and 2: ROM pairs, written through port A while loading
  signal rom_en : std_logic;
  signal rom_a_qa, rom_a_qb : std_logic_vector(17 downto 0);
  signal rom_b_qa, rom_b_qb : std_logic_vector(4 downto 0);
  signal rom_a_we, rom_b_we : std_logic;
  signal rom_a_addr : natural range 0 to 511;
  signal rom_b_addr : natural range 0 to 1023;
  signal rom_a_data : std_logic_vector(17 downto 0);
  signal rom_b_data : std_logic_vector(4 downto 0);

  ---------------------------------------------------------------------------
  -- M9K 3 and 4: RAM groups
  type harm_t  is array (0 to 63) of std_logic_vector(29 downto 0);
  type voice_t is array (0 to 255) of std_logic_vector(35 downto 0);
  signal harm  : harm_t;
  signal voice : voice_t;
  signal harm_q  : std_logic_vector(29 downto 0);
  signal voice_q : std_logic_vector(20 downto 0);

  -- Block RAM read: registered address, unregistered output. After the delayed
  -- write in the clock after a step the output would show the NEW word, but the
  -- core must see this step's read for the whole step: hold it.
  constant HOLD : boolean := true;
  signal harm_rd,  harm_hold  : std_logic_vector(29 downto 0);
  signal voice_rd   : std_logic_vector(35 downto 0);
  signal voice_hold : std_logic_vector(20 downto 0);
  signal harm_raddr  : std_logic_vector(5 downto 0) := (others => '0');
  signal voice_raddr : std_logic_vector(7 downto 0) := (others => '0');
  signal aux_rack_i, aux_wack_i : std_logic;
  signal after_step_reg : std_logic := '0';      -- the clock following a step

  -- write pending from the last step
  signal harm_wr_reg     : std_logic_vector(2 downto 0) := (others => '0');  -- lhp, cur, brk
  signal harm_addr_reg   : std_logic_vector(5 downto 0);
  signal harm_data_reg   : std_logic_vector(29 downto 0);
  signal voice_wr_reg    : std_logic_vector(1 downto 0) := (others => '0');  -- v3, v18
  signal voice_addr_reg  : std_logic_vector(3 downto 0);
  signal voice_data_reg  : std_logic_vector(20 downto 0);

  ---------------------------------------------------------------------------
  -- M9K 2 ports in the clock after a step: NOISE (constants switch back to
  -- the plain layout, in logic, as a fallback)
  constant NOISE_IN_M9K   : boolean := true;
  constant OCTSPL_IN_LUTS : boolean := true;
  signal rom_b_en     : std_logic;
  signal rom_b_addr_b : std_logic_vector(9 downto 0);
  signal sromint_areg : std_logic_vector(8 downto 0) := (others => '0');  -- last step's address
  signal noise_areg   : std_logic_vector(5 downto 0) := (others => '0');  -- last step's address
  signal noise_wr_reg : std_logic := '0';
  signal noise_wd_reg : std_logic_vector(2 downto 0) := (others => '0');
  signal after2_reg   : std_logic := '0';                                -- two clocks after a step
  signal sromint_hold, xromint_hold : std_logic_vector(4 downto 0) := (others => '0');
  signal noise_hold   : std_logic_vector(2 downto 0) := (others => '0');

  -- OCTSPL contents (the image's words at OCTSPL_BASE): a ROM, so a table in LUTs
  constant OCTSPL_ROM : octspl_t := (
    x"5", x"6", x"8", x"9", x"A", x"C", x"D", x"E", x"0", x"1", x"2", x"4", x"5", x"6", x"8", x"9",
    x"A", x"C", x"D", x"E", x"0", x"1", x"2", x"4", x"5", x"6", x"8", x"9", x"A", x"C", x"D", x"E");

  ---------------------------------------------------------------------------
  -- logic
  signal phaseram_mem : phaseram_t;
  signal noise_mem    : noise_t;
  signal octspl_mem   : octspl_t;
begin
  ---------------------------------------------------------------------------
  -- M9K 1 and 2: true dual port (amy1_dpram, an altsyncram in Quartus). Port A
  -- takes the load address while loading (the chip is stopped then), else the
  -- core's address.
  rom_ports: process (load_we, load_addr, load_data, srombs_addr, sromint_addr,
                      step_en, sromint_areg, noise_wr_reg, noise_areg, noise_wd_reg)
  begin
    rom_a_we <= '0';
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

    -- port A: SROMINT at the steps (its last address in between, as if not
    -- enabled), the NOISE write in the clock after a step, the image when loading
    rom_b_we   <= '0';
    rom_b_data <= load_data(4 downto 0);
    if step_en = '1' or not NOISE_IN_M9K then
      rom_b_addr <= to_integer(unsigned(sromint_addr));
    else
      rom_b_addr <= to_integer(unsigned(sromint_areg));
    end if;
    if load_we = '1' and in_unit(load_addr, SROMINT_BASE, 9) then
      rom_b_we   <= '1';
      rom_b_addr <= offset(load_addr, SROMINT_BASE);
    elsif load_we = '1' and in_unit(load_addr, XROMINT_BASE, 7) then
      rom_b_we   <= '1';
      rom_b_addr <= 512 + offset(load_addr, XROMINT_BASE);
    elsif NOISE_IN_M9K and load_we = '1' and in_unit(load_addr, NOISE_BASE, 6) then
      rom_b_we   <= '1';
      rom_b_addr <= 640 + offset(load_addr, NOISE_BASE);
      rom_b_data <= "00" & load_data(2 downto 0);
    elsif NOISE_IN_M9K and noise_wr_reg = '1' then       -- never in a step clock
      rom_b_we   <= '1';
      rom_b_addr <= 640 + to_integer(unsigned(noise_areg));
      rom_b_data <= "00" & noise_wd_reg;
    end if;
  end process;

  -- port B: XROMINT at the steps, the NOISE read (last step's address) in between
  rom_b_addr_b <= "100" & xromint_addr when step_en = '1' or not NOISE_IN_M9K else
                  "1010" & noise_areg;

  -- M9K 1: SROMBS (port A, words 0..255) and XROMBS (port B, words 256..383)
  rom_a: entity work.amy1_dpram
    generic map (AW => 9, DW => 18)
    port map (clk => clk, en => rom_en, we_a => rom_a_we,
              addr_a => std_logic_vector(to_unsigned(rom_a_addr, 9)), data_a => rom_a_data, q_a => rom_a_qa,
              addr_b => "10" & xrombs_addr, q_b => rom_a_qb);

  srombs_q <= rom_a_qa(16 downto 0);
  xrombs_q <= rom_a_qb(14 downto 0);

  -- M9K 2: SROMINT (port A, words 0..511) and XROMINT (port B, words 512..639)
  rom_b: entity work.amy1_dpram
    generic map (AW => 10, DW => 5)
    port map (clk => clk, en => rom_b_en, we_a => rom_b_we,
              addr_a => std_logic_vector(to_unsigned(rom_b_addr, 10)), data_a => rom_b_data, q_a => rom_b_qa,
              addr_b => rom_b_addr_b, q_b => rom_b_qb);

  -- address registers advance with the steps, and on load writes (M9K 2 on
  -- every clock when it holds NOISE)
  rom_en   <= step_en or load_we;
  rom_b_en <= '1' when NOISE_IN_M9K else rom_en;

  rom_b_regs: process (clk)
  begin
    if rising_edge(clk) then
      after2_reg   <= after_step_reg;
      noise_wr_reg <= '0';
      if step_en = '1' then
        sromint_areg <= sromint_addr;
        noise_areg   <= noise_addr;
        noise_wr_reg <= noise_we;
        noise_wd_reg <= noise_wdata;
      end if;
      if after_step_reg = '1' then         -- the ports move on at this edge
        sromint_hold <= rom_b_qa;
        xromint_hold <= rom_b_qb;
      end if;
      if after2_reg = '1' then             -- the NOISE read of the edge before
        noise_hold <= rom_b_qb(2 downto 0);
      end if;
    end if;
  end process;

  sromint_q <= rom_b_qa when after_step_reg = '1' or not NOISE_IN_M9K else sromint_hold;
  xromint_q <= rom_b_qb when after_step_reg = '1' or not NOISE_IN_M9K else xromint_hold;

  ---------------------------------------------------------------------------
  -- M9K 3: harmonic RAMs, one word per harmonic:
  --   29 LHPRAM | 28..16 HARMCURNTVAL | 15..0 HARMBRKPOINT
  harm_ram: process (clk)
    variable w : std_logic_vector(29 downto 0);
  begin
    if rising_edge(clk) then
      -- write: image word while loading, else last step's write merged into its read
      if load_we = '1' and in_unit(load_addr, HARM_BASE, 6) then
        harm(offset(load_addr, HARM_BASE)) <= load_data(29 downto 0);
      elsif harm_wr_reg /= "000" then
        w := harm_rd;                    -- this step's read of the same word
        if harm_wr_reg(0) = '1' then w(15 downto 0)  := harm_data_reg(15 downto 0);  end if;
        if harm_wr_reg(1) = '1' then w(28 downto 16) := harm_data_reg(28 downto 16); end if;
        if harm_wr_reg(2) = '1' then w(29)           := harm_data_reg(29);           end if;
        harm(to_integer(unsigned(harm_addr_reg))) <= w;
      end if;
      -- read
      if step_en = '1' then
        harm_raddr <= harmbrkpoint_addr;
      end if;
    end if;
  end process;

  harm_pending: process (clk)
  begin
    if rising_edge(clk) then
      harm_wr_reg <= "000";
      if step_en = '1' then
        harm_wr_reg   <= lhpram_we & harmcurntval_we & harmbrkpoint_we;
        harm_addr_reg <= harmbrkpoint_addr;      -- the three share one address
        harm_data_reg <= lhpram_wdata & harmcurntval_wdata & harmbrkpoint_wdata;
      end if;
    end if;
  end process;

  harm_rd  <= harm(to_integer(unsigned(harm_raddr)));
  voice_rd <= voice(to_integer(unsigned(voice_raddr)));

  hold_p: process (clk)
  begin
    if rising_edge(clk) then
      after_step_reg <= step_en;
      if after_step_reg = '1' then         -- the delayed write happens at this edge
        harm_hold  <= harm_rd;
        voice_hold <= voice_rd(20 downto 0);
      end if;
    end if;
  end process;

  harm_q  <= harm_rd  when after_step_reg = '1' or not HOLD else harm_hold;
  voice_q <= voice_rd(20 downto 0) when after_step_reg = '1' or not HOLD else voice_hold;

  harmbrkpoint_q <= harm_q(15 downto 0);
  harmcurntval_q <= harm_q(28 downto 16);
  lhpram_q       <= harm_q(29 downto 29);

  ---------------------------------------------------------------------------
  -- M9K 4: voice RAMs, one word per voice: 20..18 VOICE3 | 17..0 VOICE18
  voice_ram: process (clk)
    variable w : std_logic_vector(35 downto 0);
  begin
    if rising_edge(clk) then
      if load_we = '1' and in_unit(load_addr, VOICE_BASE, 4) then
        voice(offset(load_addr, VOICE_BASE)) <= (35 downto 21 => '0') & load_data(20 downto 0);
      elsif voice_wr_reg /= "00" then
        w := voice_rd;
        if voice_wr_reg(0) = '1' then w(17 downto 0)  := voice_data_reg(17 downto 0);  end if;
        if voice_wr_reg(1) = '1' then w(20 downto 18) := voice_data_reg(20 downto 18); end if;
        voice(to_integer(unsigned(voice_addr_reg))) <= w;
      elsif aux_wack_i = '1' then
        voice(to_integer(unsigned(aux_waddr))) <= aux_wdata;
      end if;
      if step_en = '1' then
        voice_raddr <= "0000" & voice18_addr;
      elsif aux_rack_i = '1' then
        voice_raddr <= aux_raddr;
      end if;
    end if;
  end process;

  voice_pending: process (clk)
  begin
    if rising_edge(clk) then
      voice_wr_reg <= "00";
      if step_en = '1' then
        voice_wr_reg   <= voice3_we & voice18_we;
        voice_addr_reg <= voice18_addr;          -- both share one address
        voice_data_reg <= voice3_wdata & voice18_wdata;
      end if;
    end if;
  end process;

  -- aux port: reads on clocks with no step (the core's read address is loaded
  -- at the step and its data held after it), writes when the core's delayed
  -- write and the image load leave the write port free
  aux_rack_i <= aux_re and not step_en and not load_we;
  aux_wack_i <= aux_we and not load_we when voice_wr_reg = "00" else '0';
  aux_rack   <= aux_rack_i;
  aux_wack   <= aux_wack_i;
  aux_rdata  <= voice_rd;

  voice18_q <= voice_q(17 downto 0);
  voice3_q  <= voice_q(20 downto 18);

  ---------------------------------------------------------------------------
  -- small memories in logic, as in the reference layout
  phaseram_p: process (clk)
  begin
    if rising_edge(clk) then
      if load_we = '1' then
        if in_unit(load_addr, PHASERAM_BASE, 3) then
          phaseram_mem(offset(load_addr, PHASERAM_BASE)) <= load_data(19 downto 0);
        end if;
      elsif step_en = '1' then
        if phaseram_we = '1' then
          phaseram_mem(to_integer(unsigned(phaseram_addr))) <= phaseram_wdata;
        end if;
        phaseram_q <= phaseram_mem(to_integer(unsigned(phaseram_addr)));
      end if;
    end if;
  end process;

  noise_m9k: if NOISE_IN_M9K generate
    -- valid from one clock after the step (port B, read at the edge after it)
    noise_q <= rom_b_qb(2 downto 0) when after2_reg = '1' else noise_hold;
  end generate;

  noise_logic: if not NOISE_IN_M9K generate
  noise_p: process (clk)
  begin
    if rising_edge(clk) then
      if load_we = '1' then
        if in_unit(load_addr, NOISE_BASE, 6) then
          noise_mem(offset(load_addr, NOISE_BASE)) <= load_data(2 downto 0);
        end if;
      elsif step_en = '1' then
        if noise_we = '1' then
          noise_mem(to_integer(unsigned(noise_addr))) <= noise_wdata;
        end if;
        noise_q <= noise_mem(to_integer(unsigned(noise_addr)));
      end if;
    end if;
  end process;
  end generate;

  octspl_p: process (clk)
  begin
    if rising_edge(clk) then
      if load_we = '1' then
        if in_unit(load_addr, OCTSPL_BASE, 5) and not OCTSPL_IN_LUTS then
          octspl_mem(offset(load_addr, OCTSPL_BASE)) <= load_data(3 downto 0);
        end if;
      elsif step_en = '1' then
        if OCTSPL_IN_LUTS then
          octspl_q <= OCTSPL_ROM(to_integer(unsigned(octspl_addr)));
        else
          octspl_q <= octspl_mem(to_integer(unsigned(octspl_addr)));
        end if;
      end if;
    end if;
  end process;
end architecture;
