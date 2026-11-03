-------------------------------------------------------------------------------
-- AMY1 envelope generator: the 72 piecewise-linear envelopes
--
-- Behavioural rewrite of the ENVGEN schematic block (pages 3-9), see AMY1_SPEC.md 4.2.
--
-- 64 harmonic amplitudes and 8 voice frequencies, each a current value, a
-- destination and a slope, kept in the harmonic RAMs (breakpoint 16 bits: slope 8 +
-- destination 8; current value 13 bits) and the voice RAMs (21 bits: slope 8 +
-- destination 13 in one word; current value 18 bits + voice type 2 in the other).
-- The sequencer reads one envelope at a time onto the H bus (harmonics) or the F bus
-- (voices); this block latches it, steps it and puts the new value back on the bus:
--
--   new = current + step, where step is the slope's 6-bit signed mantissa: at the
--         harmonic LSB (bit 5 of the 18-bit adder) for an amplitude, at bit 0 for a
--         frequency (P0), sign-extended above
--   if the slope is 0 (a jump) new = destination
--   the write is enabled (upenff) for a jump, or when the sequencer's rate counter
--   says so (ssen) and the value is not at its destination yet. A frequency compares
--   all 13 destination bits, an amplitude the top 8.
--
-- It also adds the noise word to amplitudes (log domain), and makes LOG for exp_rom
-- and FAN (silence the harmonic) for the phase generator via exp_rom's clrdisp.
--
-- The H and F buses are precharged in steps 0 and 1 and then driven by the RAMs or
-- the write drivers. The registers here sample them as the chip does at the end of
-- CLKN; that equals the bus as evaluated without the precharge, which is what they
-- use (h_val, f_val), so the registers can update on tick.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_envelope_generator is
  port (
    clk        : in  std_logic;
    tick       : in  std_logic;                      -- chip clock: registers update
    prech      : in  std_logic;                      -- bus precharge (steps 0, 1)
    -- sequencer
    p          : in  std_logic_vector(0 to 3);       -- slot phase P0..P3
    p2x        : in  std_logic;                      -- P2X: slope from the F bus
    odd        : in  std_logic;                      -- ODDEV
    nv         : in  std_logic;                      -- NV: ZEROB (noise muted) one clock later
    rst        : in  std_logic;                      -- RST
    clrph      : in  std_logic;                      -- CLRPH
    ssen       : in  std_logic;                      -- rate counter: step this envelope
    sel_ff     : in  std_logic;                      -- read-back of a frequency (SELFF)
    ld_flo     : in  std_logic;                      -- load frequency low bits / voice type
    h_wr       : in  std_logic;                      -- write drivers on the H bus (not ENHWRN)
    aux_wr     : in  std_logic;                      -- host drivers on the F bus (not ENAUXWRN)
    vnv_wr     : in  std_logic;                      -- new value on the F bus (ENVNVWR)
    rdbk       : in  std_logic;                      -- read-back enable (not ENRDBKN)
    -- host data
    cmnd0      : in  std_logic;                      -- command bit 0 (LHP flag)
    ib         : in  std_logic_vector(7 downto 0);   -- IB bus
    aux        : in  std_logic_vector(12 downto 0);  -- Reg B:C
    -- noise generator
    noise      : in  std_logic_vector(11 downto 0);  -- noise word, two's complement
    -- RAM read data and enables
    hbp_q      : in  std_logic_vector(15 downto 0);  -- harmonic breakpoint -> H16..1
    hbp_rd     : in  std_logic;
    hcv_q      : in  std_logic_vector(12 downto 0);  -- harmonic current value -> H29..17
    hcv_rd     : in  std_logic;
    lhp_q      : in  std_logic_vector(0 downto 0);   -- last harmonic pair flag -> H0
    lhp_rd     : in  std_logic;
    v18_q      : in  std_logic_vector(17 downto 0);  -- voice word -> F20..3
    v18_rd     : in  std_logic;
    v3_q       : in  std_logic_vector(2 downto 0);   -- voice word -> F2..0
    v3_rd      : in  std_logic;
    -- buses (RAM write data)
    h_bus      : out std_logic_vector(29 downto 0);
    f_bus      : out std_logic_vector(20 downto 0);
    -- outputs
    log        : out std_logic_vector(12 downto 0);  -- to exp_rom
    fan        : out std_logic;                      -- silence (to exp_rom, clrdisp)
    gen_sel    : out std_logic;                      -- CVNL1: the voice's noise generator
    ss         : out std_logic_vector(1 downto 0);   -- slope rate (to the sequencer)
    upenff     : out std_logic;                      -- write the new value
    upenha     : out std_logic;
    lhpulse_n  : out std_logic;                      -- LHPULSEN
    en7rdbkh   : out std_logic;                      -- read-back drivers on IB
    en7rdbkl   : out std_logic;
    rb_slope   : out std_logic_vector(7 downto 0);   -- test read-back: sign, ss1, ss0, slope
    rb_hi      : out std_logic_vector(4 downto 0);   -- read-back: F15..11
    rb_lo      : out std_logic_vector(7 downto 0)    -- read-back: F10..3 or H29..22
  );
end entity;

architecture rtl of amy1_envelope_generator is

  -- registers (initial values as the netlist model's power-up state: DREG2 and DLN
  -- cells come up 1)
  signal slp_reg,    slp_next    : std_logic_vector(4 downto 0) := (others => '1');  -- slope mantissa
  signal sign_reg,   sign_next   : std_logic := '1';                                 -- slope sign
  signal ss_reg,     ss_next     : std_logic_vector(1 downto 0) := (others => '1');  -- slope rate
  signal dlo_reg,    dlo_next    : std_logic_vector(4 downto 0) := (others => '0');  -- destination 4..0
  signal dhi_reg,    dhi_next    : std_logic_vector(7 downto 0) := (others => '1');  -- destination 12..5
  signal clrd_reg,   clrd_next   : std_logic := '0';                                 -- clear dlo
  signal chi_reg,    chi_next    : unsigned(12 downto 0) := (others => '1');         -- current 17..5
  signal clo_reg,    clo_next    : unsigned(4 downto 0) := (others => '0');          -- current 4..0
  signal vt_reg,     vt_next     : std_logic_vector(1 downto 0) := (others => '0');  -- voice type
  signal np3_reg,    np3_next    : std_logic := '0';                                 -- last clock not P3
  signal nvlo_reg,   nvlo_next   : std_logic_vector(4 downto 0) := (others => '0');  -- new value 4..0
  signal nvhi_reg,   nvhi_next   : std_logic_vector(12 downto 0) := (others => '1'); -- new value 17..5
  signal ldnv_reg,   ldnv_next   : std_logic := '0';
  signal upd_reg,    upd_next    : std_logic := '0';                                 -- UPENFFND
  signal nzd_reg,    nzd_next    : std_logic_vector(12 downto 0) := (others => '1'); -- noise-added value
  signal neg_reg,    neg_next    : std_logic := '0';                                 -- it went below 0
  signal nzv_reg,    nzv_next    : std_logic := '0';                                 -- harmonic voice
  signal lz_reg,     lz_next     : std_logic := '0';                                 -- LOG was zero
  signal lhp_reg,    lhp_next    : std_logic := '1';                                 -- LHPND
  signal rbh_reg,    rbh_next    : std_logic_vector(4 downto 0) := (others => '0');
  signal rbl_reg,    rbl_next    : std_logic_vector(7 downto 0) := (others => '1');
  signal p23_reg,    p23_next    : std_logic := '0';                                 -- not (P2 or P3), late

  -- buses
  signal h_val : std_logic_vector(29 downto 0);   -- H bus as driven (no precharge)
  signal f_val : std_logic_vector(20 downto 0);

  -- arithmetic
  signal slpz    : std_logic;
  signal dlo     : std_logic_vector(4 downto 0);
  signal dst     : std_logic_vector(12 downto 0);
  signal nval_lo : std_logic_vector(4 downto 0);
  signal nval_hi : unsigned(12 downto 0);
  signal eqn     : std_logic;
  signal upenffn : std_logic;
  signal e6nz    : unsigned(12 downto 0);
  signal bover, bneg : std_logic;
  signal log_v   : std_logic_vector(12 downto 0);
  signal logz    : std_logic;

begin

  -----------------------------------------------------------------------------
  -- The buses: 0 from any driver wins, otherwise 1 (precharge or a driver)
  -----------------------------------------------------------------------------
  process (hbp_q, hbp_rd, hcv_q, hcv_rd, lhp_q, lhp_rd, h_wr, cmnd0, ib, aux, nvhi_reg)
    variable h : std_logic_vector(29 downto 0);
  begin
    h := (others => '1');
    if lhp_rd = '1' then h(0) := lhp_q(0); end if;
    if hbp_rd = '1' then h(16 downto 1) := hbp_q; end if;
    if hcv_rd = '1' then h(29 downto 17) := hcv_q; end if;
    if h_wr = '1' then
      h(0)            := h(0) and cmnd0;
      h(8 downto 1)   := h(8 downto 1) and ib;
      h(16 downto 9)  := h(16 downto 9) and aux(7 downto 0);
      h(29 downto 17) := h(29 downto 17) and nvhi_reg;
    end if;
    h_val <= h;
  end process;

  process (v18_q, v18_rd, v3_q, v3_rd, aux_wr, vnv_wr, ib, aux, nvhi_reg, nvlo_reg)
    variable f : std_logic_vector(20 downto 0);
  begin
    f := (others => '1');
    if v3_rd = '1' then f(2 downto 0) := v3_q; end if;
    if v18_rd = '1' then f(20 downto 3) := v18_q; end if;
    if aux_wr = '1' then
      f(7 downto 0)   := f(7 downto 0) and ib;
      f(15 downto 8)  := f(15 downto 8) and aux(12 downto 5);
      f(20 downto 16) := f(20 downto 16) and aux(4 downto 0);
    end if;
    if vnv_wr = '1' then
      f(20 downto 16) := f(20 downto 16) and nvlo_reg;
      f(15 downto 3)  := f(15 downto 3) and nvhi_reg;
    end if;
    f_val <= f;
  end process;

  h_bus <= (others => '1') when prech = '1' else h_val;
  f_bus <= (others => '1') when prech = '1' else f_val;

  -----------------------------------------------------------------------------
  -- Step the envelope
  -----------------------------------------------------------------------------
  slpz <= '1' when slp_reg = "00000" else '0';
  dlo  <= dlo_reg when clrd_reg = '0' else "00000";
  dst  <= dhi_reg & dlo;

  process (slp_reg, sign_reg, clo_reg, chi_reg, slpz, np3_reg, p)
    variable lo  : unsigned(5 downto 0);
    variable op  : unsigned(12 downto 0);
    variable c5  : unsigned(0 downto 0);
  begin
    -- bits 4..0: the frequency fraction plus the mantissa
    lo := resize(unsigned(slp_reg), 6) + resize(clo_reg, 6);
    if slpz = '1' then
      nval_lo <= (others => '0');
    else
      nval_lo <= std_logic_vector(lo(4 downto 0));
    end if;
    -- carry into bit 5 only in a frequency slot (the clock after P3)
    c5(0) := lo(5) and not np3_reg;
    -- bits 17..5: the mantissa at bit 5 (amplitude), or the sign (frequency, P0)
    if p(0) = '1' then
      op := (others => sign_reg);
    else
      op := (12 downto 5 => sign_reg) & unsigned(slp_reg);
    end if;
    nval_hi <= chi_reg + op + c5;
  end process;

  -- at the destination? a frequency (P0) compares 13 bits, an amplitude 8
  process (chi_reg, dst, p)
    variable eq8, eq5 : boolean;
  begin
    eq8 := std_logic_vector(chi_reg(12 downto 5)) = dst(12 downto 5);
    eq5 := std_logic_vector(chi_reg(4 downto 0)) = dst(4 downto 0);
    if eq8 and (eq5 or p(0) = '0') then
      eqn <= '0';
    else
      eqn <= '1';
    end if;
  end process;

  upenffn <= not slpz and not (ssen and eqn);

  -----------------------------------------------------------------------------
  -- Noise: add the noise word to the amplitude (log domain)
  -----------------------------------------------------------------------------
  process (chi_reg, noise)
    variable s : unsigned(13 downto 0);
  begin
    -- 13-bit amplitude + the sign-extended noise word; s(13) is the carry out
    s := ('0' & chi_reg) + unsigned('0' & std_logic_vector(resize(signed(noise), 13)));
    e6nz  <= s(12 downto 0);
    bover <= not noise(11) and s(13);      -- positive noise, overflow
    bneg  <= noise(11) and not s(13);      -- negative noise, below zero
  end process;

  log_v <= nzd_reg when (nv = '1' or p(0) = '1' or p(2) = '1') else
           std_logic_vector(chi_reg);
  logz  <= '1' when log_v(12 downto 5) = "00000000" else '0';

  -----------------------------------------------------------------------------
  -- Next state
  -----------------------------------------------------------------------------
  process (p, p2x, odd, rst, ld_flo, h_val, f_val, sel_ff, slp_reg, sign_reg, ss_reg,
           dlo, dlo_reg, dhi_reg, chi_reg, clo_reg, vt_reg, nvlo_reg, nvhi_reg,
           ldnv_reg, upd_reg, rbh_reg, rbl_reg, nval_lo, nval_hi, slpz, dst, upenffn,
           e6nz, bover, bneg, logz)
  begin
    -- slope: H8..1 (harmonic) or F7..0 (voice, P2X); held in P3
    slp_next  <= slp_reg;
    sign_next <= sign_reg;
    ss_next   <= ss_reg;
    if p(3) = '0' then
      if p2x = '1' then
        slp_next <= f_val(4 downto 0); ss_next <= f_val(6 downto 5); sign_next <= f_val(7);
      else
        slp_next <= h_val(5 downto 1); ss_next <= h_val(7 downto 6); sign_next <= h_val(8);
      end if;
    end if;

    -- destination: H16..9 (harmonic) or F15..8 & F20..16 (voice, P2); held in P3
    dlo_next <= dlo;
    dhi_next <= dhi_reg;
    if p(3) = '0' then
      dlo_next <= f_val(20 downto 16);
      if p(2) = '1' then
        dhi_next <= f_val(15 downto 8);
      else
        dhi_next <= h_val(16 downto 9);
      end if;
    end if;
    clrd_next <= not (p(2) or p(3));

    -- current value: H29..17 (harmonic) or F15..3 (voice, P3); held in P2
    chi_next <= chi_reg;
    if p(2) = '0' then
      if p(3) = '1' then
        chi_next <= unsigned(f_val(15 downto 3));
      else
        chi_next <= unsigned(h_val(29 downto 17));
      end if;
    end if;
    clo_next <= clo_reg;
    vt_next  <= vt_reg;
    if ld_flo = '1' then
      clo_next <= unsigned(f_val(20 downto 16));
      vt_next  <= f_val(1 downto 0);
    end if;
    np3_next <= not p(3);

    -- new value: the step, or the destination for a jump
    ldnv_next <= not p(2) and not (p(1) and not odd);
    nvlo_next <= nvlo_reg;
    nvhi_next <= nvhi_reg;
    if ldnv_reg = '1' then
      nvlo_next <= nval_lo;
      if slpz = '1' then
        nvhi_next <= dst;
      else
        nvhi_next <= std_logic_vector(nval_hi);
      end if;
    end if;
    upd_next <= upd_reg;
    if p(1) = '1' then
      upd_next <= upenffn;
    end if;

    -- noise path (one clock late)
    nzd_next <= std_logic_vector(e6nz) or (12 downto 0 => bover);
    neg_next <= bneg;
    nzv_next <= not (vt_reg(1) or vt_reg(0));
    lz_next  <= logz;

    -- last harmonic pair flag
    lhp_next <= h_val(0) and not rst and p(0);

    -- read-back latches (P2)
    rbh_next <= rbh_reg;
    rbl_next <= rbl_reg;
    if p(2) = '1' then
      rbh_next <= f_val(15 downto 11);
      if sel_ff = '1' then
        rbl_next <= f_val(10 downto 3);
      else
        rbl_next <= h_val(29 downto 22);
      end if;
    end if;
    p23_next <= not (p(2) or p(3));
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if tick = '1' then
        slp_reg  <= slp_next;
        sign_reg <= sign_next;
        ss_reg   <= ss_next;
        dlo_reg  <= dlo_next;
        dhi_reg  <= dhi_next;
        clrd_reg <= clrd_next;
        chi_reg  <= chi_next;
        clo_reg  <= clo_next;
        vt_reg   <= vt_next;
        np3_reg  <= np3_next;
        nvlo_reg <= nvlo_next;
        nvhi_reg <= nvhi_next;
        ldnv_reg <= ldnv_next;
        upd_reg  <= upd_next;
        nzd_reg  <= nzd_next;
        neg_reg  <= neg_next;
        nzv_reg  <= nzv_next;
        lz_reg   <= lz_next;
        lhp_reg  <= lhp_next;
        rbh_reg  <= rbh_next;
        rbl_reg  <= rbl_next;
        p23_reg  <= p23_next;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Outputs
  -----------------------------------------------------------------------------
  log <= log_v;

  -- FAN: silence this harmonic
  process (p, nv, logz, nzv_reg, neg_reg, lz_reg)
    variable enaorf : std_logic;
  begin
    enaorf := not p(0) and not (p(2) and not nv);
    fan <= (p(1) and nv) or (enaorf and logz) or
           (not enaorf and (nzv_reg or neg_reg or lz_reg));
  end process;

  gen_sel   <= vt_reg(1);
  ss        <= ss_reg;
  upenff    <= not upenffn;
  upenha    <= not upenffn when odd = '1' else not upd_reg;
  lhpulse_n <= not (lhp_reg or (p(1) and clrph));
  en7rdbkh  <= rdbk and p23_reg;
  en7rdbkl  <= rdbk and not p23_reg;
  rb_slope  <= sign_reg & ss_reg(1) & ss_reg(0) & slp_reg;
  rb_hi     <= rbh_reg;
  rb_lo     <= rbl_reg;

end architecture;
