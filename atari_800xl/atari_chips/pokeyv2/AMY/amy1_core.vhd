-------------------------------------------------------------------------------
-- AMY1 core: the units wired together. See AMY1_SPEC.md.
--
--   host_interface   command register, A, B, C (synchronous register port)
--   command_unit     reset, handshake, decode, SCR/SOR, INT/RDY, read-back loads
--   timebase         counters, slot phases, voice and sample strobes
--   ram_addressing   harmonic and voice RAM addresses
--   envelope_generator, noise_generator, exp_rom, phase_generator, sine_rom,
--   output_accumulator
--
-- Timing: ce is one AMY internal clock (4 MHz at the spec's 8 MHz CLOCK); every register
-- updates on clk when ce is high. ce must be low on at least the clk before each ce: the
-- memories read in between. Memory contract: the address of chip clock n gives its data
-- before the ce that ends clock n; a write enabled in clock n happens at that ce.
-- The register port is synchronous to clk; a command written in clock n is busy from
-- clock n+2.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.amy1_pkg.all;

entity amy1_core is
  port (
    clk        : in  std_logic;
    ce         : in  std_logic;                      -- one AMY internal clock
    reset      : in  std_logic;                      -- synchronous, active high

    -- registers: 0 command, 1 A, 2 B, 3 C
    addr       : in  std_logic_vector(1 downto 0);
    we         : in  std_logic;
    wdata      : in  std_logic_vector(7 downto 0);
    rdata      : out std_logic_vector(7 downto 0);
    rdy        : out std_logic;                      -- INT/RDY as the SOR selects it

    -- audio
    sample     : out signed(16 downto 0);            -- the last sample, two's complement
    sample_stb : out std_logic;                      -- a new sample (one ce)
    sample_v0  : out std_logic;                      -- INDIVIDUAL mode: it is voice 0's
    noise_init : out std_logic;                      -- NZINIT: the host is loading the Noise RAM

    -- memories (logical addresses)
    phaseram_addr      : out std_logic_vector(2 downto 0);
    phaseram_we        : out std_logic;
    phaseram_wdata     : out std_logic_vector(19 downto 0);
    phaseram_q         : in  std_logic_vector(19 downto 0);
    noise_addr         : out std_logic_vector(5 downto 0);
    noise_we           : out std_logic;
    noise_wdata        : out std_logic_vector(2 downto 0);
    noise_q            : in  std_logic_vector(2 downto 0);
    harm_addr          : out std_logic_vector(5 downto 0);    -- the three harmonic RAMs
    lhpram_we          : out std_logic;
    lhpram_wdata       : out std_logic_vector(0 downto 0);
    lhpram_q           : in  std_logic_vector(0 downto 0);
    harmbrkpoint_we    : out std_logic;
    harmbrkpoint_wdata : out std_logic_vector(15 downto 0);
    harmbrkpoint_q     : in  std_logic_vector(15 downto 0);
    harmcurntval_we    : out std_logic;
    harmcurntval_wdata : out std_logic_vector(12 downto 0);
    harmcurntval_q     : in  std_logic_vector(12 downto 0);
    voice_addr         : out std_logic_vector(3 downto 0);    -- the two voice RAMs
    voice18_we         : out std_logic;
    voice18_wdata      : out std_logic_vector(17 downto 0);
    voice18_q          : in  std_logic_vector(17 downto 0);
    voice3_we          : out std_logic;
    voice3_wdata       : out std_logic_vector(2 downto 0);
    voice3_q           : in  std_logic_vector(2 downto 0);
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

  -- host interface
  signal cmnd : std_logic_vector(7 downto 0);
  signal cmd_wr : std_logic;
  signal reg_a, reg_c : std_logic_vector(7 downto 0);
  signal reg_b : std_logic_vector(4 downto 0);
  signal reg_bc : std_logic_vector(12 downto 0);

  -- command unit
  signal rst, ld_rb, ld_rc : std_logic;
  signal config : config_t;
  signal cmd : host_cmd_t;

  -- timebase
  signal p : std_logic_vector(0 to 3);
  signal cnt : std_logic_vector(6 downto 0);
  signal cntv, voice : std_logic_vector(2 downto 0);
  signal p2x, sync, odd, ssen, new_voice, upd_freq, zerob, nv, ld_voice, ld_flo,
         ld_samp, outstb, v0 : std_logic;
  signal outstb_d : std_logic := '0';

  -- RAM addresses
  signal harm_a : std_logic_vector(5 downto 0);

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
  signal fjump : std_logic;

begin

  ----------------------------------------------------------------------------
  -- Control
  ----------------------------------------------------------------------------
  u_host_interface: entity work.amy1_host_interface port map (
    clk => clk, ce => ce, addr => addr, we => we, wdata => wdata, rdata => rdata,
    ld_rb => ld_rb, ld_rc => ld_rc, readback => readback,
    cmnd => cmnd, cmd_wr => cmd_wr, reg_a => reg_a, reg_b => reg_b, reg_c => reg_c);
  reg_bc <= reg_b & reg_c;

  u_command_unit: entity work.amy1_command_unit port map (
    clk => clk, ce => ce, reset => reset, cmnd => cmnd, cmd_wr => cmd_wr,
    p => p, sync => sync, upd_freq => upd_freq,
    env_wr => env_wr, noise_wr => noise_wr,
    rst => rst, config => config, cmd => cmd, ld_rb => ld_rb, ld_rc => ld_rc, rdy => rdy);

  u_timebase: entity work.amy1_timebase port map (
    clk => clk, ce => ce, rst => rst,
    sel40 => config.sel40, individual => config.individual,
    last_pair => last_pair, slope_rate => slope_rate,
    p => p, cnt => cnt, p2x => p2x, sync => sync, odd => odd, ssen => ssen,
    cntv => cntv, voice => voice, new_voice => new_voice, upd_freq => upd_freq,
    zerob => zerob, nv => nv, ld_voice => ld_voice, ld_flo => ld_flo,
    ld_samp => ld_samp, outstb => outstb, v0 => v0);

  u_ram_addressing: entity work.amy1_ram_addressing port map (
    clk => clk, ce => ce,
    p => p, cnt => cnt(6 downto 2), p2x => p2x, odd => odd, cntv => cntv,
    upd_freq => upd_freq, cmd => cmd, fjump => fjump,
    harm_addr => harm_a, voice_addr => voice_addr);
  harm_addr <= harm_a;

  ----------------------------------------------------------------------------
  -- Envelopes and noise
  ----------------------------------------------------------------------------
  u_envelope_generator: entity work.amy1_envelope_generator port map (
    clk => clk, ce => ce,
    p => p, p2x => p2x, odd => odd, nv => nv, ssen => ssen, ld_flo => ld_flo,
    upd_freq => upd_freq, rst => rst, clrph => config.clrph, cmd => cmd,
    reg_a => reg_a, reg_bc => reg_bc, noise => noise,
    hbp_q => harmbrkpoint_q, hbp_we => harmbrkpoint_we, hbp_wdata => harmbrkpoint_wdata,
    hcv_q => harmcurntval_q, hcv_we => harmcurntval_we, hcv_wdata => harmcurntval_wdata,
    lhp_q => lhpram_q, lhp_we => lhpram_we, lhp_wdata => lhpram_wdata,
    v18_q => voice18_q, v18_we => voice18_we, v18_wdata => voice18_wdata,
    v3_q => voice3_q, v3_we => voice3_we, v3_wdata => voice3_wdata,
    log => log, fan => fan, noise_gen => noise_gen, slope_rate => slope_rate,
    last_pair => last_pair, host_wr => env_wr, readback => readback, fjump => fjump);

  u_noise_generator: entity work.amy1_noise_generator port map (
    clk => clk, ce => ce,
    p => p, sync => sync, odd => odd, sel40 => config.sel40, hadr => harm_a,
    host_mode => config.nzinit, cmd => cmd, host_data => reg_a(2 downto 0),
    host_wr => noise_wr, noise_gen => noise_gen, mute => zerob,
    noise => noise, serial => bout,
    ram_addr => noise_addr, ram_we => noise_we, ram_wdata => noise_wdata, ram_q => noise_q);

  ----------------------------------------------------------------------------
  -- Data path
  ----------------------------------------------------------------------------
  u_exp_rom: entity work.amy1_exp_rom port map (
    clk => clk, ce => ce, log => log, fan => fan, xo => xo, clrdisp => clrdisp,
    base_addr => xrombs_addr, base_q => xrombs_q, int_addr => xromint_addr, int_q => xromint_q);

  u_phase_generator: entity work.amy1_phase_generator port map (
    clk => clk, ce => ce,
    ld_voice => ld_voice, voice => voice, cnt => cnt(6 downto 1), clrph => config.clrph,
    xo => xo, clrdisp => clrdisp, arg => arg,
    ram_addr => phaseram_addr, ram_we => phaseram_we, ram_wdata => phaseram_wdata,
    ram_q => phaseram_q);

  u_sine_rom: entity work.amy1_sine_rom port map (
    clk => clk, ce => ce, arg => arg, hs => hs,
    base_addr => srombs_addr, base_q => srombs_q, int_addr => sromint_addr, int_q => sromint_q);

  u_output_accumulator: entity work.amy1_output_accumulator port map (
    clk => clk, ce => ce, hs => hs, load => ld_samp, sample => sample);

  -- the sample strobe: the first clock of OUTSTB
  process (clk)
  begin
    if rising_edge(clk) then
      if ce = '1' then
        outstb_d <= outstb;
      end if;
    end if;
  end process;
  sample_stb <= outstb and not outstb_d;
  sample_v0  <= v0;
  noise_init <= config.nzinit;

end architecture;
