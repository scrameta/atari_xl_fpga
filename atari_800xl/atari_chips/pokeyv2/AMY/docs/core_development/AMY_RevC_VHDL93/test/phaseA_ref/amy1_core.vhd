-------------------------------------------------------------------------------
-- AMY1 core: the units wired together. See AMY1_SPEC.md and INTERFACE_REVIEW.md.
--
--   host_interface   pins, command register, A, B, C
--   command_unit     reset, handshake, decode, SCR/SOR, INT/RDY, read-back loads
--   timebase         counters, slot phases, voice and sample strobes
--   ram_addressing   harmonic and voice RAM addresses
--   envelope_generator, noise_generator, exp_rom, phase_generator, sine_rom,
--   output_accumulator
--
-- Phase A: the chip's pins and six-step clock are kept, so the core stays sample-identical
-- to the netlist core.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.amy1_pkg.all;

entity amy1_core is
  port (
    clk     : in  std_logic;
    step_en : in  std_logic;                     -- advance one sequencer step

    -- chip pins (active low as on the real part; CLOCK is replaced by step_en)
    pin_resetn   : in  std_logic;
    pin_test     : in  std_logic;                -- not modelled (test modes dropped)
    pin_oen      : in  std_logic;
    pin_csn      : in  std_logic;
    pin_wrn      : in  std_logic;
    pin_rdn      : in  std_logic;
    pin_a        : in  std_logic_vector(1 downto 0);
    pin_db_in    : in  std_logic_vector(7 downto 0);
    pin_db_drive : in  std_logic;                -- host is driving DB
    pin_db_out   : out std_logic_vector(7 downto 0);
    pin_db_oe    : out std_logic_vector(7 downto 0);
    pin_intrdy   : out std_logic;                -- READY mode: low while a command runs
    pin_samp     : out std_logic_vector(15 downto 0);  -- SAMP0 is muxed with bit 16 on the pin
    pin_outstbn  : out std_logic;
    pin_v0       : out std_logic;                -- voice 0 (INDIVIDUAL) / period (SUM)

    -- internal 17-bit sample latch (use this rather than pin_samp)
    samp_latch   : out std_logic_vector(16 downto 0);
    samp_load    : out std_logic;                -- the latch is being loaded
    noise_init   : out std_logic;                -- NZINIT: the host is loading the Noise RAM

    -- memories (synchronous read: the address in step k gives data in step k+1)
    phaseram_addr      : out std_logic_vector(2 downto 0);
    phaseram_we        : out std_logic;
    phaseram_wdata     : out std_logic_vector(19 downto 0);
    phaseram_q         : in  std_logic_vector(19 downto 0);
    noise_addr         : out std_logic_vector(5 downto 0);
    noise_we           : out std_logic;
    noise_wdata        : out std_logic_vector(2 downto 0);
    noise_q            : in  std_logic_vector(2 downto 0);
    lhpram_addr        : out std_logic_vector(5 downto 0);
    lhpram_we          : out std_logic;
    lhpram_wdata       : out std_logic_vector(0 downto 0);
    lhpram_q           : in  std_logic_vector(0 downto 0);
    harmbrkpoint_addr  : out std_logic_vector(5 downto 0);
    harmbrkpoint_we    : out std_logic;
    harmbrkpoint_wdata : out std_logic_vector(15 downto 0);
    harmbrkpoint_q     : in  std_logic_vector(15 downto 0);
    harmcurntval_addr  : out std_logic_vector(5 downto 0);
    harmcurntval_we    : out std_logic;
    harmcurntval_wdata : out std_logic_vector(12 downto 0);
    harmcurntval_q     : in  std_logic_vector(12 downto 0);
    voice18_addr       : out std_logic_vector(3 downto 0);
    voice18_we         : out std_logic;
    voice18_wdata      : out std_logic_vector(17 downto 0);
    voice18_q          : in  std_logic_vector(17 downto 0);
    voice3_addr        : out std_logic_vector(3 downto 0);
    voice3_we          : out std_logic;
    voice3_wdata       : out std_logic_vector(2 downto 0);
    voice3_q           : in  std_logic_vector(2 downto 0);
    octspl_addr        : out std_logic_vector(4 downto 0);
    octspl_q           : in  std_logic_vector(3 downto 0);
    xrombs_addr        : out std_logic_vector(6 downto 0);
    xrombs_q           : in  std_logic_vector(14 downto 0);
    xromint_addr       : out std_logic_vector(6 downto 0);
    xromint_q          : in  std_logic_vector(4 downto 0);
    srombs_addr        : out std_logic_vector(7 downto 0);
    srombs_q           : in  std_logic_vector(16 downto 0);
    sromint_addr       : out std_logic_vector(8 downto 0);
    sromint_q          : in  std_logic_vector(4 downto 0)
  );
end entity;

architecture rtl of amy1_core is

  -- step sequencer
  signal step_reg, step_next : unsigned(2 downto 0) := (others => '0');
  signal clk_ph, clkn_ph, t10, tick, sample : std_logic;
  signal clkn_seen : std_logic := '0';

  -- host interface
  signal cmnd : std_logic_vector(7 downto 0);
  signal cmd_wr : std_logic;
  signal reg_a, reg_c : std_logic_vector(7 downto 0);
  signal reg_b : std_logic_vector(4 downto 0);
  signal reg_bc : std_logic_vector(12 downto 0);

  -- command unit
  signal rst, ld_rb, ld_rc, int_rdy : std_logic;
  signal config : config_t;
  signal cmd : host_cmd_t;

  -- timebase
  signal p : std_logic_vector(0 to 3);
  signal cnt : std_logic_vector(6 downto 0);
  signal cntv, voice : std_logic_vector(2 downto 0);
  signal p2x, sync, odd, ssen, new_voice, upd_freq, zerob, nv, ld_voice, ld_flo,
         ld_samp, outstb, v0, newout : std_logic;

  -- RAM addresses
  signal harm_addr : std_logic_vector(5 downto 0);
  signal voice_addr : std_logic_vector(3 downto 0);

  -- envelope generator
  signal log : std_logic_vector(12 downto 0);
  signal readback : std_logic_vector(12 downto 0);
  signal fan, noise_gen, last_pair, env_wr : std_logic;
  signal slope_rate : std_logic_vector(1 downto 0);

  -- noise generator
  signal noise : std_logic_vector(11 downto 0);
  signal noise_wr, bout : std_logic;

  -- data path
  signal xo : std_logic_vector(17 downto 0);
  signal clrdisp : std_logic;
  signal arg : std_logic_vector(13 downto 0);
  signal hs : std_logic_vector(12 downto 0);
  signal samp_oe : std_logic;

begin

  ----------------------------------------------------------------------------
  -- Step sequencer (replaces the on-chip two-phase clock generator)
  --   step 0  PRECH            step 3  -
  --   step 1  CLK, PRECH       step 4  CLKN
  --   step 2  CLK, T10MHZ      step 5  CLKN, T10MHZ
  -- The chip's registers sample at the end of CLKN and show the value from CLK; tick
  -- (step 0) updates them, the first one after the first CLKN.
  ----------------------------------------------------------------------------
  step_next <= (others => '0') when step_reg = 5 else step_reg + 1;
  clk_ph  <= '1' when step_reg = 1 or step_reg = 2 else '0';
  t10     <= '1' when step_reg = 2 or step_reg = 5 else '0';
  clkn_ph <= '1' when step_reg = 4 or step_reg = 5 else '0';
  tick    <= step_en when step_reg = 0 and clkn_seen = '1' else '0';
  sample  <= step_en when step_reg = 5 else '0';

  process (clk)
  begin
    if rising_edge(clk) then
      if step_en = '1' then
        step_reg <= step_next;
      end if;
      if sample = '1' then
        clkn_seen <= '1';
      end if;
    end if;
  end process;

  ----------------------------------------------------------------------------
  -- Control
  ----------------------------------------------------------------------------
  u_host_interface: entity work.amy1_host_interface port map (
    clk => clk, step_en => step_en, tick => tick,
    pin_a => pin_a, pin_csn => pin_csn, pin_rdn => pin_rdn, pin_wrn => pin_wrn,
    pin_db_in => pin_db_in, pin_db_drive => pin_db_drive,
    pin_db_out => pin_db_out, pin_db_oe => pin_db_oe,
    ld_rb => ld_rb, ld_rc => ld_rc, readback => readback,
    cmnd => cmnd, cmd_wr => cmd_wr, reg_a => reg_a, reg_b => reg_b, reg_c => reg_c);

  u_command_unit: entity work.amy1_command_unit port map (
    clk => clk, step_en => step_en, tick => tick, t10 => t10, resetn => pin_resetn,
    cmnd => cmnd, cmd_wr => cmd_wr,
    p => p, sync => sync, upd_freq => upd_freq,
    env_wr => env_wr, noise_wr => noise_wr,
    rst => rst, config => config, cmd => cmd, ld_rb => ld_rb, ld_rc => ld_rc,
    int_rdy => int_rdy);

  u_timebase: entity work.amy1_timebase port map (
    clk => clk, step_en => step_en, tick => tick, clkn_ph => clkn_ph, rst => rst,
    sel40 => config.sel40, individual => config.individual,
    last_pair => last_pair, slope_rate => slope_rate,
    p => p, cnt => cnt, p2x => p2x, sync => sync, odd => odd, ssen => ssen,
    cntv => cntv, voice => voice, new_voice => new_voice, upd_freq => upd_freq,
    zerob => zerob, nv => nv, ld_voice => ld_voice, ld_flo => ld_flo,
    ld_samp => ld_samp, outstb => outstb, v0 => v0, newout => newout);

  u_ram_addressing: entity work.amy1_ram_addressing port map (
    clk => clk, step_en => step_en, tick => tick, clk_ph => clk_ph,
    p => p, cnt => cnt(6 downto 2), p2x => p2x, odd => odd, cntv => cntv,
    upd_freq => upd_freq, cmd => cmd,
    harm_addr => harm_addr, voice_addr => voice_addr);

  ----------------------------------------------------------------------------
  -- Envelopes and noise
  ----------------------------------------------------------------------------
  u_envelope_generator: entity work.amy1_envelope_generator port map (
    clk => clk, tick => tick, clkn_ph => clkn_ph,
    p => p, p2x => p2x, odd => odd, nv => nv, ssen => ssen, ld_flo => ld_flo,
    upd_freq => upd_freq, rst => rst, clrph => config.clrph, cmd => cmd,
    reg_a => reg_a, reg_bc => reg_bc, noise => noise,
    hbp_q => harmbrkpoint_q, hbp_we => harmbrkpoint_we, hbp_wdata => harmbrkpoint_wdata,
    hcv_q => harmcurntval_q, hcv_we => harmcurntval_we, hcv_wdata => harmcurntval_wdata,
    lhp_q => lhpram_q, lhp_we => lhpram_we, lhp_wdata => lhpram_wdata,
    v18_q => voice18_q, v18_we => voice18_we, v18_wdata => voice18_wdata,
    v3_q => voice3_q, v3_we => voice3_we, v3_wdata => voice3_wdata,
    log => log, fan => fan, noise_gen => noise_gen, slope_rate => slope_rate,
    last_pair => last_pair, host_wr => env_wr, readback => readback);

  reg_bc <= reg_b & reg_c;

  -- the RAMs take the netlist's inverted address lines
  lhpram_addr       <= not harm_addr;
  harmbrkpoint_addr <= not harm_addr;
  harmcurntval_addr <= not harm_addr;
  voice18_addr      <= not voice_addr;
  voice3_addr       <= not voice_addr;

  u_noise_generator: entity work.amy1_noise_generator port map (
    clk => clk, tick => tick, clk_ph => clk_ph,
    p => p, sync => sync, odd => odd, hadr => harm_addr,
    host_mode => config.nzinit, cmd => cmd, host_data => reg_a(2 downto 0),
    host_wr => noise_wr, noise_gen => noise_gen, mute => zerob,
    noise => noise, serial => bout,
    ram_addr => noise_addr, ram_we => noise_we, ram_wdata => noise_wdata, ram_q => noise_q);

  ----------------------------------------------------------------------------
  -- Data path
  ----------------------------------------------------------------------------
  u_exp_rom: entity work.amy1_exp_rom port map (
    clk => clk, tick => tick, log => log, fan => fan, xo => xo, clrdisp => clrdisp,
    base_addr => xrombs_addr, base_q => xrombs_q, int_addr => xromint_addr, int_q => xromint_q);
  octspl_addr <= (others => '0');

  u_phase_generator: entity work.amy1_phase_generator port map (
    clk => clk, tick => tick, sample => sample, clkn_ph => clkn_ph,
    ld_voice => ld_voice, voice => voice, cnt => cnt(6 downto 1), clrph => config.clrph,
    xo => xo, clrdisp => clrdisp, arg => arg,
    ram_addr => phaseram_addr, ram_we => phaseram_we, ram_wdata => phaseram_wdata,
    ram_q => phaseram_q);

  u_sine_rom: entity work.amy1_sine_rom port map (
    clk => clk, tick => tick, arg => arg, hs => hs,
    base_addr => srombs_addr, base_q => srombs_q, int_addr => sromint_addr, int_q => sromint_q);

  samp_oe <= not pin_oen;
  u_output_accumulator: entity work.amy1_output_accumulator port map (
    clk => clk, tick => tick, sample => sample, clkn_ph => clkn_ph,
    hs => hs, load => ld_samp, test => '0', outstb => outstb, samp_oe => samp_oe,
    ld_samp => samp_load, samp_latch => samp_latch, samp_pin => pin_samp);

  ----------------------------------------------------------------------------
  -- Pins
  ----------------------------------------------------------------------------
  pin_intrdy  <= int_rdy;
  pin_outstbn <= not outstb;
  pin_v0      <= v0 when config.individual = '1' else newout;
  noise_init  <= config.nzinit;

end architecture;
