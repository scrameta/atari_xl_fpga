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
-- The envelope RAMs are the envelopes' state: this block owns their writes (the new
-- value, and the host's breakpoints, LHP flags and voice types); the addresses come
-- from amy1_ram_addressing. Inside, the RAM data and the write data meet on the H bus
-- (harmonics) and the F bus (voices), as in the chip: a 0 from any driver wins.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.amy1_pkg.all;

entity amy1_envelope_generator is
  port (
    clk        : in  std_logic;
    ce         : in  std_logic;                      -- chip clock enable: registers update
    -- timebase
    p          : in  std_logic_vector(0 to 3);       -- slot phase P0..P3
    p2x        : in  std_logic;                      -- P1 one clock late: slope from the F bus
    odd        : in  std_logic;                      -- odd sample period
    nv         : in  std_logic;                      -- noise muted one clock ago (new voice)
    ssen       : in  std_logic;                      -- step this envelope (slope rate)
    ld_flo     : in  std_logic;                      -- load frequency low bits / voice type
    upd_freq   : in  std_logic;                      -- the voice's frequency is stepped
    -- command unit
    rst        : in  std_logic;
    clrph      : in  std_logic;
    cmd        : in  host_cmd_t;
    -- host registers
    reg_a      : in  std_logic_vector(7 downto 0);   -- slope
    reg_bc     : in  std_logic_vector(12 downto 0);  -- B:C: destination, voice type
    -- noise generator
    noise      : in  std_logic_vector(11 downto 0);  -- noise word, two's complement
    -- envelope RAMs (addresses from amy1_ram_addressing)
    hbp_q      : in  std_logic_vector(15 downto 0);  -- harmonic breakpoint: destination 8, slope 8
    hbp_we     : out std_logic;
    hbp_wdata  : out std_logic_vector(15 downto 0);
    hcv_q      : in  std_logic_vector(12 downto 0);  -- harmonic current value
    hcv_we     : out std_logic;
    hcv_wdata  : out std_logic_vector(12 downto 0);
    lhp_q      : in  std_logic_vector(0 downto 0);   -- last harmonic pair flag
    lhp_we     : out std_logic;
    lhp_wdata  : out std_logic_vector(0 downto 0);
    v18_q      : in  std_logic_vector(17 downto 0);  -- voice word, bits 20..3
    v18_we     : out std_logic;
    v18_wdata  : out std_logic_vector(17 downto 0);
    v3_q       : in  std_logic_vector(2 downto 0);   -- voice word, bits 2..0
    v3_we      : out std_logic;
    v3_wdata   : out std_logic_vector(2 downto 0);
    -- outputs
    log        : out std_logic_vector(12 downto 0);  -- to exp_rom
    fan        : out std_logic;                      -- silence (to exp_rom, clrdisp)
    noise_gen  : out std_logic;                      -- the voice's noise generator
    slope_rate : out std_logic_vector(1 downto 0);   -- to the timebase (ssen)
    fjump      : out std_logic;                      -- P1 after a frequency jump: its current value
    last_pair  : out std_logic;                      -- LHP flag seen: next voice
    host_wr    : out std_logic;                      -- the command's RAM write is happening
    readback   : out std_logic_vector(12 downto 0)   -- for B (12..8) and C (7..0)
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

  -- RAM write control (each a register; the write happens at the ce ending its clock)
  signal enwrh_reg,  enwrh_next  : std_logic := '0';   -- harmonic current value (envelope)
  signal enwrbp_reg, enwrbp_next : std_logic := '0';   -- harmonic breakpoint (host)
  signal enwrlh_reg, enwrlh_next : std_logic := '0';   -- LHP flag (host)
  signal upffw_reg,  upffw_next  : std_logic := '0';   -- frequency update window, from P1
  signal enwrv_reg,  enwrv_next  : std_logic := '1';   -- voice current value (envelope); power-up: on
  signal enwrvi_reg, enwrvi_next : std_logic := '1';   -- voice breakpoint (host); power-up: on
  signal fjump_reg,  fjump_next  : std_logic := '0';   -- the clock after a frequency jump's write
  signal ennzwr_reg, ennzwr_next : std_logic := '1';   -- voice type (host); power-up: on
  signal h_wr, v_wr, aux_wr, vnv_wr, sel_ff, upenha, upenff : std_logic;
  signal hbp_rd, hcv_rd, lhp_rd, v18_rd, v3_rd : std_logic;
  signal we_hbp, we_hcv, we_lhp, we_v18, we_v3 : std_logic;
  signal jump_now : std_logic;
  signal wr_harm, wr_lhp, wr_freq, wr_type : std_logic;

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
  process (hbp_q, hbp_rd, hcv_q, hcv_rd, lhp_q, lhp_rd, h_wr, cmd, reg_a, reg_bc, nvhi_reg)
    variable h : std_logic_vector(29 downto 0);
  begin
    h := (others => '1');
    if lhp_rd = '1' then h(0) := lhp_q(0); end if;
    if hbp_rd = '1' then h(16 downto 1) := hbp_q; end if;
    if hcv_rd = '1' then h(29 downto 17) := hcv_q; end if;
    if h_wr = '1' then
      h(0)            := h(0) and cmd.lhp;
      h(8 downto 1)   := h(8 downto 1) and reg_a;
      h(16 downto 9)  := h(16 downto 9) and reg_bc(7 downto 0);
      h(29 downto 17) := h(29 downto 17) and nvhi_reg;
    end if;
    h_val <= h;
  end process;

  process (v18_q, v18_rd, v3_q, v3_rd, aux_wr, vnv_wr, fjump_reg, reg_a, reg_bc, nvhi_reg, nvlo_reg)
    variable f : std_logic_vector(20 downto 0);
  begin
    f := (others => '1');
    if v3_rd = '1' then f(2 downto 0) := v3_q; end if;
    if v18_rd = '1' then f(20 downto 3) := v18_q; end if;
    if aux_wr = '1' then
      f(7 downto 0)   := f(7 downto 0) and reg_a;
      f(15 downto 8)  := f(15 downto 8) and reg_bc(12 downto 5);
      f(20 downto 16) := f(20 downto 16) and reg_bc(4 downto 0);
    end if;
    if vnv_wr = '1' then
      f(20 downto 16) := f(20 downto 16) and nvlo_reg;
      f(15 downto 3)  := f(15 downto 3) and nvhi_reg;
    end if;
    if fjump_reg = '1' then                    -- the jump's current value: destination, fraction 0
      f(20 downto 16) := (others => '0');
      f(15 downto 3)  := f(15 downto 3) and reg_bc;
    end if;
    f_val <= f;
  end process;

  -----------------------------------------------------------------------------
  -- RAM writes: the envelope's new value (harmonic in P3, voice in P1 of an update
  -- period), the host's breakpoint, LHP flag and voice type. A RAM is read when its
  -- group is not written.
  -----------------------------------------------------------------------------
  wr_harm <= '1' when cmd.op = OP_WR_HARM else '0';
  wr_lhp  <= '1' when cmd.op = OP_WR_LHP  else '0';
  wr_freq <= '1' when cmd.op = OP_WR_FREQ else '0';
  wr_type <= '1' when cmd.op = OP_WR_TYPE else '0';
  sel_ff  <= '1' when p(2) = '1' and cmd.op = OP_RD_FREQ else '0';

  enwrh_next  <= upenha and p(2);
  enwrbp_next <= wr_harm and p(1);
  enwrlh_next <= wr_lhp and p(1);
  upffw_next  <= upd_freq when p(1) = '1' else upffw_reg;
  enwrv_next  <= upffw_reg and p(0) and upenff;
  enwrvi_next <= p(3) and wr_freq;
  -- A frequency jump (WR_FREQ with a zero mantissa) also loads the voice's current value, in
  -- P1 straight after the breakpoint write (P0), as the 1983 spec says ("loaded immediate into
  -- the FF current value field"): the netlist applied it at the voice's next update, every
  -- other sample period, and a second write before then lost it. The breakpoint and current
  -- value are separate voice words, so this is a second write; ram_addressing gives it the
  -- command's voice and word 0. If the envelope updates a voice in that P1, the jump's write
  -- takes the clock and that voice's step waits for its next update.
  fjump_next  <= enwrvi_reg and wr_freq when reg_a(4 downto 0) = "00000" else '0';
  ennzwr_next <= p(3) and wr_type;

  h_wr   <= enwrbp_reg or enwrh_reg or enwrlh_reg;
  v_wr   <= enwrv_reg or enwrvi_reg or fjump_reg;
  aux_wr <= enwrvi_reg or ennzwr_reg;
  vnv_wr <= enwrv_reg and not fjump_reg;

  -- A breakpoint write with a zero slope mantissa (a jump) also loads the current value
  -- at once, as the 1983 spec says ("loaded immediate into the HA current value field"):
  -- the netlist applied it at the harmonic's next update, up to two sample periods
  -- later, and a second write before then lost it (Q1). Same clock and address as the
  -- breakpoint write; the next update still applies the jump as before.
  jump_now <= enwrbp_reg when reg_a(4 downto 0) = "00000" else '0';
  we_hcv <= enwrh_reg or jump_now;
  we_hbp <= enwrbp_reg;
  we_lhp <= enwrlh_reg;
  we_v18 <= v_wr;
  we_v3  <= aux_wr;
  hbp_rd <= not h_wr and not we_hbp;
  hcv_rd <= not h_wr and not we_hcv;
  lhp_rd <= not h_wr and not we_lhp;
  v18_rd <= not v_wr and not we_v18;
  v3_rd  <= not aux_wr and not we_v3;

  hcv_we <= we_hcv;  hcv_wdata <= reg_bc(7 downto 0) & "00000" when jump_now = '1' else h_val(29 downto 17);
  hbp_we <= we_hbp;  hbp_wdata <= h_val(16 downto 1);
  lhp_we <= we_lhp;  lhp_wdata <= h_val(0 downto 0);
  fjump <= fjump_reg;
  v18_we <= we_v18;  v18_wdata <= f_val(20 downto 3);
  v3_we  <= we_v3;   v3_wdata  <= f_val(2 downto 0);
  host_wr <= enwrbp_reg or enwrlh_reg or aux_wr;

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
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if ce = '1' then
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
        enwrh_reg  <= enwrh_next;
        enwrbp_reg <= enwrbp_next;
        enwrlh_reg <= enwrlh_next;
        upffw_reg  <= upffw_next;
        enwrv_reg  <= enwrv_next;
        enwrvi_reg <= enwrvi_next;
        fjump_reg  <= fjump_next;
        ennzwr_reg <= ennzwr_next;
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

  noise_gen  <= vt_reg(1);
  slope_rate <= ss_reg;
  upenff     <= not upenffn;
  upenha     <= not upenffn when odd = '1' else not upd_reg;
  last_pair  <= lhp_reg or (p(1) and clrph);
  readback   <= rbh_reg & rbl_reg;

end architecture;
