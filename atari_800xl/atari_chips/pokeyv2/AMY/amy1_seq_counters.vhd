-------------------------------------------------------------------------------
-- AMY1 sequencer, page 15: clock, sample and voice counters, period end, RAM addressing
--
-- Behavioural rewrite of SEQCONT page 15 and the v3 host synchronisation edit (p2y),
-- see AMY1_SPEC.md 4.7.
--
-- Clock counter cnt (7 bits) counts the chip clocks of a sample period; four clocks
-- (P0..P3) make a harmonic slot, so cnt(6:2) is the harmonic. The period ends at
--   clock 125 (64 harmonics), clock 77 with SEL40H (40 harmonics), clock 1 in TST0;
-- the end decode (clrv_n low) restarts the voice counter; two clocks later sync
-- restarts the clock counter and advances the sample counter.
-- Sample counter sam (7 bits): bit 0 = ODDEV (odd/even sample); bits 1..6 give the
--   slope enable SSEN for the envelope's slope speed SS (every 2, 8, 32, 128 samples).
-- Voice counter cntv (3 bits): advances at each last-harmonic-pair pulse, stops at 7.
--   NEWV marks a new voice (or the period end); VOICE is cntv taken at P1.
-- RAM addressing: harmonic RAMs = (cnt(6:2), halsb) or, in P2 of a host harmonic command
--   (p2y), the command's harmonic; voice RAMs = (cntv, ~p2x) or the command's voice
--   (vfrecyc). The address lines are the netlist's inverted ones (a fixed permutation).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_seq_counters is
  port (
    clk        : in  std_logic;
    step_en    : in  std_logic;                     -- one step
    tick       : in  std_logic;                     -- chip clock: registers update
    clk_ph     : in  std_logic;
    clkn_ph    : in  std_logic;
    rst        : in  std_logic;
    tst0       : in  std_logic;                     -- test mode 0: one harmonic per period
    sel40      : in  std_logic;                     -- SEL40H: 40 harmonics
    lhpulse_n  : in  std_logic;                     -- last harmonic pair: next voice
    ss         : in  std_logic_vector(1 downto 0);  -- slope speed of the current harmonic
    p1         : in  std_logic;
    hcmd       : in  std_logic;                     -- RDHA or WRHA or D2: host harmonic command
    cmnd       : in  std_logic_vector(5 downto 0);  -- command register (harmonic / voice number)
    wr_lhp     : in  std_logic;                     -- SCWRLH
    halsb      : in  std_logic;
    vfrecyc    : in  std_logic;
    we_hcv, we_hbp, we_lhp, we_v18, we_v3 : in std_logic;
    en_hwr_n, en_vwr_n, en_auxwr_n : in std_logic;
    h          : in  std_logic_vector(29 downto 0); -- H bus (harmonic RAM write data)
    f          : in  std_logic_vector(20 downto 0); -- F bus (voice RAM write data)
    cnt        : out std_logic_vector(6 downto 0);
    cnt15      : out std_logic;                     -- clock 15 of the period
    end40      : out std_logic;                     -- clock 77 (CLKN latch): SUM mode NEWOUT
    sync       : out std_logic;
    odd        : out std_logic;                     -- ODDEV
    ssen_n     : out std_logic;                     -- SSENN
    newv       : out std_logic;
    upff       : out std_logic;                     -- the voice's frequency is updated
    voice      : out std_logic_vector(2 downto 0);
    voice0     : out std_logic;                     -- VOICEDZ
    p2x        : out std_logic;                     -- P1 one clock late
    hadr_n     : out std_logic_vector(5 downto 0);  -- HADR5N..HADR0N
    -- RAM ports
    lhp_addr, hbp_addr, hcv_addr : out std_logic_vector(5 downto 0);
    lhp_we, hbp_we, hcv_we, lhp_rd, hbp_rd, hcv_rd : out std_logic;
    lhp_wdata  : out std_logic_vector(0 downto 0);
    hbp_wdata  : out std_logic_vector(15 downto 0);
    hcv_wdata  : out std_logic_vector(12 downto 0);
    v18_addr, v3_addr : out std_logic_vector(3 downto 0);
    v18_we, v3_we, v18_rd, v3_rd : out std_logic;
    v18_wdata  : out std_logic_vector(17 downto 0);
    v3_wdata   : out std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of amy1_seq_counters is

  -- chip-clock registers
  signal cnt_reg,   cnt_next   : unsigned(6 downto 0) := (others => '0');
  signal sam_reg,   sam_next   : unsigned(6 downto 0) := (others => '0');
  signal cntv_reg,  cntv_next  : unsigned(2 downto 0) := (others => '0');
  signal voice_reg, voice_next : unsigned(2 downto 0) := (others => '0');
  signal clrvd_reg, clrvd_next : std_logic := '0';   -- CLRVD: clrv_n one clock late
  signal clrcc_reg, clrcc_next : std_logic := '1';   -- CLRCC: the period end, two clocks late
  signal p2x_reg,   p2x_next   : std_logic := '0';

  -- step-level: CLKN latch of the clock-77 decode, CLK latch of p2y
  signal end40_reg, p2y_reg : std_logic := '0';
  signal end40_i, p2y : std_logic;

  signal new40, clrv_n, cv0, newv_i, sync_i : std_logic;
  signal hadr : std_logic_vector(5 downto 0);
  signal vadr : std_logic_vector(3 downto 0);

begin

  sync_i <= clrcc_reg or rst;

  -- period end
  new40  <= '1' when cnt_reg = 77 and rst = '0' else '0';
  clrv_n <= '0' when (cnt_reg = 125 and rst = '0') or (new40 = '1' and sel40 = '1')
                  or (cnt_reg = 1 and tst0 = '1') else '1';
  end40_i <= new40 when clkn_ph = '1' else end40_reg;

  -- voice
  cv0    <= '1' when lhpulse_n = '0' and cntv_reg /= 7 else '0';
  newv_i <= cv0 or not clrv_n;

  -- p2y: P2 of a host harmonic command (CLK latch)
  p2y <= (hcmd and p2x_reg) when clk_ph = '1' else p2y_reg;

  process (sync_i, cnt_reg, rst, sam_reg, clrcc_reg, clrv_n, cntv_reg, cv0, p1, voice_reg)
  begin
    if sync_i = '1' then
      cnt_next <= (others => '0');
    else
      cnt_next <= cnt_reg + 1;
    end if;
    if rst = '1' then
      sam_next <= (others => '0');
    elsif clrcc_reg = '1' then
      sam_next <= sam_reg + 1;
    else
      sam_next <= sam_reg;
    end if;
    if rst = '1' or clrv_n = '0' then
      cntv_next <= (others => '0');
    elsif cv0 = '1' then
      cntv_next <= cntv_reg + 1;
    else
      cntv_next <= cntv_reg;
    end if;
    voice_next <= voice_reg;
    if p1 = '1' then
      voice_next <= cntv_reg;
    end if;
    clrvd_next <= clrv_n;
    clrcc_next <= not clrvd_reg;
    p2x_next   <= p1;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if step_en = '1' then
        end40_reg <= end40_i;
        p2y_reg   <= p2y;
      end if;
      if tick = '1' then
        cnt_reg   <= cnt_next;
        sam_reg   <= sam_next;
        cntv_reg  <= cntv_next;
        voice_reg <= voice_next;
        clrvd_reg <= clrvd_next;
        clrcc_reg <= clrcc_next;
        p2x_reg   <= p2x_next;
      end if;
    end if;
  end process;

  -- RAM addresses
  hadr <= (cmnd(5 downto 1) & (cmnd(0) and not wr_lhp)) when p2y = '1'
          else std_logic_vector(cnt_reg(6 downto 2)) & halsb;
  vadr <= (cmnd(2 downto 0) & not cmnd(4)) when vfrecyc = '1'
          else std_logic_vector(cntv_reg) & p2x_reg;
  hadr_n <= not hadr;

  lhp_addr <= not hadr;  hbp_addr <= not hadr;  hcv_addr <= not hadr;
  v18_addr <= not vadr;  v3_addr  <= not vadr;
  lhp_we <= we_lhp;  hbp_we <= we_hbp;  hcv_we <= we_hcv;  v18_we <= we_v18;  v3_we <= we_v3;
  lhp_rd <= en_hwr_n and not we_lhp;
  hbp_rd <= en_hwr_n and not we_hbp;
  hcv_rd <= en_hwr_n and not we_hcv;
  v18_rd <= en_vwr_n and not we_v18;
  v3_rd  <= en_auxwr_n and not we_v3;
  lhp_wdata <= h(0 downto 0);
  hbp_wdata <= h(16 downto 1);
  hcv_wdata <= h(29 downto 17);
  v18_wdata <= f(20 downto 3);
  v3_wdata  <= f(2 downto 0);

  -- outputs
  cnt    <= std_logic_vector(cnt_reg);
  cnt15  <= '1' when cnt_reg = 15 else '0';
  end40  <= end40_i;
  sync   <= sync_i;
  odd    <= sam_reg(0);
  ssen_n <= '0' when (ss = "11")
                  or (ss = "10" and sam_reg(2 downto 1) = 0)
                  or (ss = "01" and sam_reg(4 downto 1) = 0)
                  or (ss = "00" and sam_reg(6 downto 1) = 0) else '1';
  newv   <= newv_i;
  upff   <= newv_i and (cntv_reg(0) xor sam_reg(0));
  voice  <= std_logic_vector(voice_reg);
  voice0 <= '1' when voice_reg = 0 else '0';
  p2x    <= p2x_reg;

end architecture;
