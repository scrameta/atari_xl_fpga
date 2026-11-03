-------------------------------------------------------------------------------
-- AMY1 sequencer, page 17: slot phases, command handshake, voice and sample strobes
--
-- Behavioural rewrite of SEQCONT page 17, see AMY1_SPEC.md 4.7.
--
-- Slot phase: P0..P3 = the clock counter's two LSBs, one clock late (P0 in reset).
--
-- Command handshake: loading the command register sets a latch; when the load ends,
-- the request passes two T10MHZ flip-flops (LDCM3, LDCM4) and two chip-clock registers
-- (SEQ1D, SEQB2), which sets the busy latch. Busy ends when the command has been done
-- (rstbsyp_n low, two clocks later). INT/RDY: READY mode = not busy, INT mode = the
-- end-of-command pulse.
--
-- Voice strobes: zerob mutes the noise word from a new voice's P0 until P3; NV and
-- LDVOICE follow it. Sample strobes: the sample is latched (ild_samp_n) at P0, two
-- slots after a voice load (every voice in INDIVIDUAL mode, voice 0 in SUM mode);
-- OUTSTB follows two clocks later; V0 marks voice 0's sample in INDIVIDUAL mode.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity amy1_seq_timing is
  port (
    clk        : in  std_logic;
    step_en    : in  std_logic;                     -- one step
    tick       : in  std_logic;                     -- chip clock: registers update
    clkn_ph    : in  std_logic;
    t10        : in  std_logic;                     -- T10MHZ (steps 2, 5)
    rst        : in  std_logic;
    cnt0, cnt1 : in  std_logic;                     -- clock counter LSBs
    cnt15      : in  std_logic;                     -- clock 15 of the period (latched)
    newv       : in  std_logic;                     -- a new voice starts
    voice0     : in  std_logic;                     -- the voice is 0 (VOICEDZ)
    sum_n      : in  std_logic;                     -- INDIVIDUAL mode (SUMMODEN)
    ld_cmnd    : in  std_logic;                     -- the command register is being loaded
    rdyn       : in  std_logic;                     -- INT mode (RDYN)
    rstbsyp_n  : in  std_logic;                     -- the command is done (active low)
    en_rdbk_n  : in  std_logic;
    p          : out std_logic_vector(0 to 3);
    zerob      : out std_logic;
    nv         : out std_logic;
    ld_voice_n : out std_logic;                     -- LDVOICEN
    ld_flo_n   : out std_logic;                     -- LDFLONZN
    ild_samp_n : out std_logic;                     -- ILDSAMPN
    outstb_n   : out std_logic;                     -- OUTSTBN
    v0         : out std_logic;
    seqb2      : out std_logic;
    busy_n     : out std_logic;                     -- SEQBSYDN
    en_slp     : out std_logic;                     -- ENSLP
    intrdy     : out std_logic                      -- INT/RDY pin
  );
end entity;

architecture rtl of amy1_seq_timing is

  -- chip-clock registers
  signal ph_reg,     ph_next     : std_logic_vector(0 to 3) := (others => '0');  -- P0..P3
  signal newvw_reg,  newvw_next  : std_logic := '0';   -- NEWVWIN
  signal nv_reg,     nv_next     : std_logic := '0';
  signal ldvn_reg,   ldvn_next   : std_logic := '0';
  signal ldvm1_reg,  ldvm1_next  : std_logic := '0';
  signal ldvm2_reg,  ldvm2_next  : std_logic := '0';
  signal ilsa_reg,   ilsa_next   : std_logic := '0';   -- ILSAN1D
  signal ostbn_reg,  ostbn_next  : std_logic := '0';
  signal ostb_reg,   ostb_next   : std_logic := '0';
  signal cnt15_reg,  cnt15_next  : std_logic := '0';
  signal v0_reg,     v0_next     : std_logic := '0';
  signal seq1d_reg,  seq1d_next  : std_logic := '0';
  signal seqb2_reg,  seqb2_next  : std_logic := '0';
  signal bsy1d_reg,  bsy1d_next  : std_logic := '0';
  signal rbsyp_reg,  rbsyp_next  : std_logic := '0';   -- RSTBSYPD
  signal rbsy_reg,   rbsy_next   : std_logic := '0';   -- RSTBSY

  -- step-level: gate latches, the CLKN latch, the T10MHZ flip-flops
  signal zerob_reg, x49_reg, cmd_reg, x60_reg, ldvl_reg : std_logic := '0';
  signal m3_reg, m4_reg : std_logic := '0';
  signal l3n_reg, l4n_reg : std_logic := '1';   -- power-up: SEQB2 (1 before the first CLK) resets the slaves
  signal zerob_i, x49, iv0, cmd, x60, bsy, ldvl : std_logic;
  signal m3, l3n, q3, m4, l4n, q4 : std_logic;
  signal ildsamp_n, ldvmod : std_logic;

begin

  -- zerob: set from a new voice's P0 (or reset), cleared in P3
  zerob_i <= not ph_reg(3) and ((ph_reg(0) and newvw_reg) or zerob_reg or rst);

  -- sample strobe: CLKN latch of LDVMOD2D
  ldvl      <= ldvm2_reg when clkn_ph = '1' else ldvl_reg;
  ildsamp_n <= not (ph_reg(0) and ldvl);
  ldvmod    <= not ldvn_reg and (voice0 or sum_n);

  -- V0: set by OUTSTB, held until clock 15
  x49 <= not (ostb_reg and not x49_reg) and not cnt15_reg;
  iv0 <= ostb_reg and not x49;

  -- command handshake
  cmd <= (ld_cmnd or cmd_reg) and not rst and not seqb2_reg;     -- X54: a command waits
  -- LDCM3, LDCM4: T10MHZ master-slave flip-flops, the slaves (held inverted) reset by SEQB2
  m3  <= (not ld_cmnd and cmd) when t10 = '0' else m3_reg;
  l3n <= not m3_reg when t10 = '1' else (seqb2_reg or l3n_reg);
  q3  <= not seqb2_reg and not l3n;
  m4  <= q3 when t10 = '0' else m4_reg;
  l4n <= not m4_reg when t10 = '1' else (seqb2_reg or l4n_reg);
  q4  <= not seqb2_reg and not l4n;
  x60 <= not seqb2_reg and not (not x60_reg and not rst and not rbsy_reg);
  bsy <= not x60 and not rst and not rbsy_reg;

  process (cnt0, cnt1, rst, ph_reg, newv, newvw_reg, zerob_i, nv_reg, ldvmod, ldvm1_reg,
           ildsamp_n, ilsa_reg, ostbn_reg, cnt15, iv0, q4, seq1d_reg, bsy, rstbsyp_n, rbsyp_reg)
    variable r0, r1 : std_logic;
  begin
    r0 := cnt0 or rst;
    r1 := cnt1 or rst;
    ph_next <= (r1 and r0) & (not r1 and not r0) & (not r1 and r0) & (r1 and not r0);
    newvw_next <= newvw_reg;
    if ph_reg(1) = '1' then
      newvw_next <= newv;
    end if;
    nv_next   <= zerob_i;
    ldvn_next <= not (ph_reg(3) and nv_reg);
    ldvm1_next <= ldvm1_reg;
    ldvm2_next <= ldvm2_reg;
    if ph_reg(0) = '1' then
      ldvm1_next <= ldvmod;
      ldvm2_next <= ldvm1_reg;
    end if;
    ilsa_next  <= ildsamp_n;
    ostbn_next <= ilsa_reg;
    ostb_next  <= ostbn_reg;
    cnt15_next <= cnt15;
    v0_next    <= iv0;
    seq1d_next <= q4;
    seqb2_next <= seq1d_reg;
    bsy1d_next <= bsy;
    rbsyp_next <= not rstbsyp_n;
    rbsy_next  <= rbsyp_reg;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if step_en = '1' then
        zerob_reg <= zerob_i;
        x49_reg   <= x49;
        cmd_reg   <= cmd;
        x60_reg   <= x60;
        ldvl_reg  <= ldvl;
        m3_reg <= m3; l3n_reg <= l3n; m4_reg <= m4; l4n_reg <= l4n;
      end if;
      if tick = '1' then
        ph_reg    <= ph_next;
        newvw_reg <= newvw_next;
        nv_reg    <= nv_next;
        ldvn_reg  <= ldvn_next;
        ldvm1_reg <= ldvm1_next;
        ldvm2_reg <= ldvm2_next;
        ilsa_reg  <= ilsa_next;
        ostbn_reg <= ostbn_next;
        ostb_reg  <= ostb_next;
        cnt15_reg <= cnt15_next;
        v0_reg    <= v0_next;
        seq1d_reg <= seq1d_next;
        seqb2_reg <= seqb2_next;
        bsy1d_reg <= bsy1d_next;
        rbsyp_reg <= rbsyp_next;
        rbsy_reg  <= rbsy_next;
      end if;
    end if;
  end process;

  p          <= ph_reg;
  zerob      <= zerob_i;
  nv         <= nv_reg;
  ld_voice_n <= ldvn_reg;
  ld_flo_n   <= not (ph_reg(3) and newvw_reg);
  ild_samp_n <= ildsamp_n;
  outstb_n   <= ostbn_reg;
  v0         <= v0_reg;
  seqb2      <= seqb2_reg;
  busy_n     <= not (bsy and bsy1d_reg);
  en_slp     <= en_rdbk_n and bsy and bsy1d_reg;
  intrdy     <= (not (bsy or seq1d_reg or q4) and not rdyn) or (rbsy_reg and rdyn);

end architecture;
