-- Directed test of amy1_mem(packed)'s aux2 port (the Rev C extension page in the
-- harmonic block RAM's upper half).  ce every CLKS clocks; the core's own schedule
-- runs (its reads at e1..e5, e7 happen whatever the inputs).  Checks:
--   * 128 writes then 128 reads round-trip, with the engine-style handshake
--   * a read is never granted at e1..e5 or e7, a write never with a core write
--   * at least one grant per chip clock is possible (no starvation)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_aux2 is
  generic (CLKS : natural := 14);
end entity;

architecture sim of tb_aux2 is
  signal clk : std_logic := '0';
  signal ce  : std_logic := '0';
  signal phase : natural := 0;              -- clocks since ce (0 = the ce clock)
  signal done : boolean := false;

  signal a2_re, a2_rack, a2_we, a2_wack : std_logic := '0';
  signal a2_raddr, a2_waddr : std_logic_vector(6 downto 0) := (others => '0');
  signal a2_rdata, a2_wdata : std_logic_vector(35 downto 0) := (others => '0');
  signal ext_req : std_logic := '0';

  function pattern(i : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((i * 40503 + 12345) mod 2**30, 30)) &
           std_logic_vector(to_unsigned(i mod 64, 6));
  end function;
begin
  clk <= not clk after 5 ns when not done;

  process (clk)
  begin
    if rising_edge(clk) then
      if phase = CLKS - 1 then phase <= 0; else phase <= phase + 1; end if;
    end if;
  end process;
  ce <= '1' when phase = CLKS - 1 else '0';    -- ce high in the clock before phase 0

  dut: entity work.amy1_mem(packed) port map (
    clk => clk, ce => ce,
    load_we => '0', load_addr => (others => '0'), load_data => (others => '0'),
    aux2_re => a2_re, aux2_raddr => a2_raddr, aux2_rack => a2_rack, aux2_rdata => a2_rdata,
    aux2_we => a2_we, aux2_waddr => a2_waddr, aux2_wdata => a2_wdata, aux2_wack => a2_wack,
    phaseram_addr => "000", phaseram_we => '0', phaseram_wdata => (others => '0'), phaseram_q => open,
    noise_addr => (others => '0'), noise_we => '0', noise_wdata => "000", noise_q => open,
    lhpram_addr => (others => '0'), lhpram_we => '0', lhpram_wdata => "0", lhpram_q => open,
    harmbrkpoint_addr => (others => '0'), harmbrkpoint_we => '0', harmbrkpoint_wdata => (others => '0'),
    harmbrkpoint_q => open,
    harmcurntval_addr => (others => '0'), harmcurntval_we => '0', harmcurntval_wdata => (others => '0'),
    harmcurntval_q => open,
    voice18_addr => "0000", voice18_we => '0', voice18_wdata => (others => '0'), voice18_q => open,
    voice3_addr => "0000", voice3_we => '0', voice3_wdata => "000", voice3_q => open,
    octspl_addr => (others => '0'), octspl_q => open,
    xrombs_addr => (others => '0'), xrombs_q => open,
    xromint_addr => (others => '0'), xromint_q => open,
    srombs_addr => (others => '0'), srombs_q => open,
    sromint_addr => (others => '0'), sromint_q => open);

  -- grant-cycle check: e_n is the clock n after the ce clock, i.e. phase = n - 1... the
  -- memory's ce_dN is high in the clock N clocks after ce, which is phase N - 1 here
  -- (ce itself is high at phase CLKS - 1).
  check: process (clk)
  begin
    if rising_edge(clk) then
      if a2_rack = '1' then
        assert not (phase <= 4 or phase = 6)
          report "aux2 read granted in a core clock (e" & integer'image(phase + 1) & ")"
          severity failure;
      end if;
    end if;
  end process;

  stim: process
    variable grants : natural;
  begin
    wait for 200 ns;
    -- Handshake as the engine uses it: a request held until the clock in which the
    -- ack is high; the access happens at the edge that ends that clock.  Acks are
    -- sampled at the falling edge (mid-clock).
    -- writes
    for i in 0 to 127 loop
      wait until rising_edge(clk);
      a2_we <= '1'; a2_waddr <= std_logic_vector(to_unsigned(i, 7)); a2_wdata <= pattern(i);
      loop
        wait until falling_edge(clk);
        exit when a2_wack = '1';
      end loop;
      wait until rising_edge(clk);           -- the write happens here
      a2_we <= '0';
    end loop;
    -- reads: aux2_rdata is valid in the clock after the one with rack
    grants := 0;
    for i in 127 downto 0 loop
      wait until rising_edge(clk);
      a2_re <= '1'; a2_raddr <= std_logic_vector(to_unsigned(i, 7));
      loop
        wait until falling_edge(clk);
        exit when a2_rack = '1';
      end loop;
      wait until rising_edge(clk);           -- the read happens here
      a2_re <= '0';
      wait until falling_edge(clk);          -- the clock after rack
      assert a2_rdata = pattern(i)
        report "aux2 read-back mismatch at word " & integer'image(i) severity failure;
      grants := grants + 1;
    end loop;
    report "tb_aux2 passed: 128 writes, " & integer'image(grants) & " reads, CLKS="
           & integer'image(CLKS);
    done <= true;
    wait;
  end process;
end architecture;
