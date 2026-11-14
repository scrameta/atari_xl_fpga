library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_ext_memory is end;
architecture sim of tb_ext_memory is
  signal clk : std_logic := '0';
  signal ce : std_logic := '0';
  signal nr : natural range 0 to 13 := 0;
  signal reset, enabled, ext_we, ext_ack : std_logic := '0';
  signal kind : std_logic_vector(1 downto 0) := "00";
  signal index : std_logic_vector(5 downto 0) := (others=>'0');
  signal value : std_logic_vector(7 downto 0) := (others=>'0');
  signal slot : std_logic_vector(5 downto 0) := (others=>'0');
  signal step : std_logic := '0';
  signal d,s : std_logic_vector(5 downto 0);
  signal po,pn : std_logic_vector(17 downto 0);
  signal offset_w : std_logic_vector(17 downto 0);
begin
  clk <= not clk after 5 ns;
  process(clk)
  begin
    if rising_edge(clk) then
      if nr=13 then nr<=0; ce<='1'; else nr<=nr+1; ce<='0'; end if;
    end if;
  end process;
  offset_w <= std_logic_vector(unsigned(po)+to_unsigned(7,18));
  dut: entity work.amy1_mem(packed) port map (
    clk=>clk, ce=>ce, ext_reset=>reset, ext_enable=>enabled,
    ext_we=>ext_we, ext_kind=>kind, ext_index=>index,
    ext_value=>value, ext_ack=>ext_ack, phase_slot=>slot,
    offset_step=>step, detune_q=>d, stoch_q=>s,
    offset_old_q=>po, offset_new_q=>pn, offset_wdata=>offset_w,
    load_we=>'0', load_addr=>(others=>'0'), load_data=>(others=>'0'),
    aux_re=>'0',aux_raddr=>(others=>'0'),aux_rack=>open,aux_rdata=>open,
    aux_we=>'0',aux_waddr=>(others=>'0'),aux_wdata=>(others=>'0'),aux_wack=>open,
    phaseram_addr=>(others=>'0'),phaseram_we=>'0',phaseram_wdata=>(others=>'0'),phaseram_q=>open,
    noise_addr=>(others=>'0'),noise_we=>'0',noise_wdata=>(others=>'0'),noise_q=>open,
    lhpram_addr=>(others=>'0'),lhpram_we=>'0',lhpram_wdata=>(others=>'0'),lhpram_q=>open,
    harmbrkpoint_addr=>(others=>'0'),harmbrkpoint_we=>'0',harmbrkpoint_wdata=>(others=>'0'),harmbrkpoint_q=>open,
    harmcurntval_addr=>(others=>'0'),harmcurntval_we=>'0',harmcurntval_wdata=>(others=>'0'),harmcurntval_q=>open,
    voice18_addr=>(others=>'0'),voice18_we=>'0',voice18_wdata=>(others=>'0'),voice18_q=>open,
    voice3_addr=>(others=>'0'),voice3_we=>'0',voice3_wdata=>(others=>'0'),voice3_q=>open,
    octspl_addr=>(others=>'0'),octspl_q=>open,
    xrombs_addr=>(others=>'0'),xrombs_q=>open,
    xromint_addr=>(others=>'0'),xromint_q=>open,
    srombs_addr=>(others=>'0'),srombs_q=>open,
    sromint_addr=>(others=>'0'),sromint_q=>open
  );
  process
    procedure issue(k: std_logic_vector(1 downto 0);
                    i: natural; v: natural) is
    begin
      wait until falling_edge(clk);
      kind<=k; index<=std_logic_vector(to_unsigned(i,6));
      value<=std_logic_vector(to_unsigned(v,8)); ext_we<='1';
      wait until falling_edge(clk); ext_we<='0';
      for t in 0 to 100 loop
        wait until rising_edge(clk);
        exit when ext_ack='1';
        assert t < 100 report "extension RAM ack timeout" severity failure;
      end loop;
    end procedure;
  begin
    reset<='1'; wait for 25 ns; reset<='0'; enabled<='1';
    slot<=std_logic_vector(to_unsigned(5,6));
    wait for 250 ns;
    assert d="000000" and s="000000" report "reset default coefficients" severity failure;
    issue("01",5,17);
    wait for 300 ns;
    assert d="010001" report "detune coefficient retrieval" severity failure;
    issue("10",5,42);
    wait for 300 ns;
    assert s="101010" report "stochasticity coefficient retrieval" severity failure;
    step<='1';
    wait for 300 ns;
    assert pn/=std_logic_vector(to_unsigned(0,18)) report "offset accumulator not updated" severity failure;
    reset<='1'; wait for 25 ns; reset<='0';
    wait for 300 ns;
    assert d="000000" and s="000000" report "logical reset did not clear coefficients" severity failure;
    report "tb_ext_memory passed"; wait;
  end process;
end architecture;
