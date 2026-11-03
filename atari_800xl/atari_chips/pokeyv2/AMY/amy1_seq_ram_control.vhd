-------------------------------------------------------------------------------
-- AMY1 sequencer, page 18: RAM read and write control
--
-- Behavioural rewrite of SEQCONT page 18 and the v3 host synchronisation edit (xy2),
-- see AMY1_SPEC.md 4.7.
--
-- Write enables, each a chip-clock register gated with CLKN (written in steps 4, 5):
--   harmonic current value   envelope update in P2 (upenha)
--   harmonic breakpoint      host write (WRHA) in P1
--   LHP flag                 host write (wr_lhp) in P1
--   voice current value      envelope update in P0 (upff window, upenff)
--   voice breakpoint/type    host write (WRFF / WRFFNZ) in P3, both voice words
-- The harmonic RAMs are read whenever none of them is written, the voice RAMs likewise.
-- Read-back (RDHA, RDFF): the RAM word is latched into Reg C at P3 and Reg B at P1 of
-- the following slot; selff marks a frequency read. halsb is the harmonic address LSB
-- (odd harmonic in P1, and P3 of odd periods); vfrecyc selects the command's voice.
-- rstbsyp_n: one of the commands that end the busy state has been done.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity amy1_seq_ram_control is
  port (
    clk        : in  std_logic;
    step_en    : in  std_logic;                     -- one step
    tick       : in  std_logic;                     -- chip clock: registers update
    clk_ph     : in  std_logic;
    clkn_ph    : in  std_logic;
    p          : in  std_logic_vector(0 to 3);
    odd        : in  std_logic;                     -- ODDEV
    rdha, wrha, rdff, wrff, wrffnz : in std_logic;  -- command decodes
    wr_lhp     : in  std_logic;                     -- SCWRLH
    ld_scr, ld_sor : in std_logic;
    wrnz_n     : in  std_logic;
    upff       : in  std_logic;                     -- voice update this period
    upenff     : in  std_logic;                     -- envelope: write the new value
    upenha     : in  std_logic;
    -- RAM strobes
    we_hcv, we_hbp, we_lhp, we_v18, we_v3 : out std_logic;   -- WRHANV, WRHBP, WRLH, WRVUP, WRVLO
    en_hwr_n   : out std_logic;                     -- ENHWRN: no harmonic RAM write
    en_vwr_n   : out std_logic;                     -- ENVWRN: no voice-18 write
    en_auxwr_n : out std_logic;                     -- ENAUXWRN: no voice-3 (host) write
    en_vnvwr   : out std_logic;                     -- ENVNVWR: new voice value on the F bus
    en_rdbk_n  : out std_logic;                     -- ENRDBKN
    ld_rb      : out std_logic;                     -- LDRB
    ld_rc      : out std_logic;                     -- LDRC
    sel_ff     : out std_logic;                     -- SELFF
    halsb      : out std_logic;
    vfrecyc    : out std_logic;
    rstbsyp_n  : out std_logic                      -- RSTBSYPN
  );
end entity;

architecture rtl of amy1_seq_ram_control is

  signal halsb_reg,  halsb_next  : std_logic := '0';
  signal vfrec_reg,  vfrec_next  : std_logic := '0';
  signal enwrh_reg,  enwrh_next  : std_logic := '0';   -- harmonic current value write
  signal enwrbp_reg, enwrbp_next : std_logic := '0';   -- harmonic breakpoint write
  signal enwrlh_reg, enwrlh_next : std_logic := '0';   -- LHP flag write
  signal upffw_reg,  upffw_next  : std_logic := '0';   -- UPFFWIN
  signal enwrv_reg,  enwrv_next  : std_logic := '0';   -- ENWRV (active low)
  signal enwrvi_reg, enwrvi_next : std_logic := '0';   -- ENWRVI (active low)
  signal ennzwr_reg, ennzwr_next : std_logic := '0';   -- ENNZWR (active low)
  signal rdfa1_reg,  rdfa1_next  : std_logic := '0';
  signal rdfa2_reg,  rdfa2_next  : std_logic := '0';

  -- P1 and P3 half a clock late: latched at the end of CLK, shown from CLKN
  signal p15m_reg, p15_reg, p35m_reg, p35_reg : std_logic := '0';
  signal p15m, p15, p35m, p35 : std_logic;

  signal rdfa, envwr, enauxwr, enha, ldrb_i : std_logic;

begin

  p15m <= p(1) when clk_ph = '1' else p15m_reg;
  p35m <= p(3) when clk_ph = '1' else p35m_reg;
  p15  <= p15m when clkn_ph = '1' else p15_reg;
  p35  <= p35m when clkn_ph = '1' else p35_reg;

  rdfa <= not rdfa1_reg and ((not upff and rdff) or rdha);

  process (p, odd, upff, rdff, wrff, wrffnz, upenha, wrha, wr_lhp, upffw_reg, upenff,
           rdfa, rdfa1_reg, upffw_reg)
  begin
    halsb_next  <= p(0) or (odd and p(2));
    vfrec_next  <= (not upff and rdff and p(1)) or (p(3) and (wrff or wrffnz));
    enwrh_next  <= upenha and p(2);
    enwrbp_next <= wrha and p(1);
    enwrlh_next <= wr_lhp and p(1);
    upffw_next  <= upffw_reg;
    if p(1) = '1' then
      upffw_next <= upff;
    end if;
    enwrv_next  <= not (upffw_reg and p(0) and upenff);
    enwrvi_next <= not (p(3) and wrff);
    ennzwr_next <= not (p(3) and wrffnz);
    rdfa1_next  <= rdfa1_reg;
    if p(1) = '1' then
      rdfa1_next <= rdfa;
    end if;
    rdfa2_next  <= rdfa1_reg;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if step_en = '1' then
        p15m_reg <= p15m; p15_reg <= p15; p35m_reg <= p35m; p35_reg <= p35;
      end if;
      if tick = '1' then
        halsb_reg  <= halsb_next;
        vfrec_reg  <= vfrec_next;
        enwrh_reg  <= enwrh_next;
        enwrbp_reg <= enwrbp_next;
        enwrlh_reg <= enwrlh_next;
        upffw_reg  <= upffw_next;
        enwrv_reg  <= enwrv_next;
        enwrvi_reg <= enwrvi_next;
        ennzwr_reg <= ennzwr_next;
        rdfa1_reg  <= rdfa1_next;
        rdfa2_reg  <= rdfa2_next;
      end if;
    end if;
  end process;

  envwr   <= not enwrv_reg or not enwrvi_reg;
  enauxwr <= not enwrvi_reg or not ennzwr_reg;
  enha    <= not (enwrbp_reg or enwrlh_reg);
  ldrb_i  <= p15 and rdfa2_reg;

  we_hcv <= enwrh_reg and clkn_ph;
  we_hbp <= enwrbp_reg and clkn_ph;
  we_lhp <= enwrlh_reg and clkn_ph;
  we_v18 <= envwr and clkn_ph;
  we_v3  <= enauxwr and clkn_ph;

  en_hwr_n   <= not (enwrbp_reg or enwrh_reg or enwrlh_reg);
  en_vwr_n   <= not envwr;
  en_auxwr_n <= not enauxwr;
  en_vnvwr   <= not enwrv_reg;
  en_rdbk_n  <= not (rdha or rdff);
  ld_rb      <= ldrb_i;
  ld_rc      <= p35 and rdfa1_reg;
  sel_ff     <= p(2) and rdff;
  halsb      <= halsb_reg;
  vfrecyc    <= vfrec_reg;
  rstbsyp_n  <= not (ld_sor or ld_scr or not wrnz_n or ldrb_i or not enha or enauxwr);

end architecture;
