-------------------------------------------------------------------------------
-- AMY1 sequencer, page 16: reset, system control register, command decode
--
-- Behavioural rewrite of SEQCONT page 16, see AMY1_SPEC.md 4.7.
--
-- Reset: the RESET pin is synchronised by two master-slave flip-flops on T10MHZ
-- (the master follows while T10MHZ is low, the slave takes it while T10MHZ is high)
-- and a chip-clock register, giving rst.
--
-- Command decode, while a command is executing (busy):
--   1x......  D2: Last Harmonic Pair flag (SC1 = 0) or Noise RAM write (SC1 = 1)
--   11......  read harmonic amplitude        01......  write harmonic breakpoint
--   00011...  read frequency                 00001...  write frequency breakpoint
--   00010...  write voice type               0011.... SCR (with SEQB2)  0010.... SOR
-- SCR: SC0 = SEQRUN (sftrst_n), SC1 = NZINIT request; both cleared by reset. The run
-- state and NZINIT take effect at SYNC. clrph (HALT) = not SEQRUN, or reset.
-- Noise RAM write: a D2 command with NZINIT, strobed in P2 and one clock later.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity amy1_seq_commands is
  port (
    clk      : in  std_logic;
    step_en  : in  std_logic;                      -- one step
    tick     : in  std_logic;                      -- chip clock: registers update
    t10      : in  std_logic;                      -- T10MHZ (steps 2, 5)
    resetn   : in  std_logic;                      -- RESET pin
    cmnd     : in  std_logic_vector(7 downto 0);   -- command register
    busy     : in  std_logic;                      -- a command is executing (not SEQBSYDN)
    seqb2    : in  std_logic;                      -- command sync, stage 2
    p2       : in  std_logic;
    sync     : in  std_logic;
    rst      : out std_logic;
    clrph    : out std_logic;                      -- HALT: clear phases
    nzinit   : out std_logic;
    d2, rdha, wrha, rdff, wrff, wrffnz : out std_logic;
    ld_scr   : out std_logic;                      -- LDSCON (active high)
    ld_sor   : out std_logic;                      -- LDSOR
    wr_lhp   : out std_logic;                      -- SCWRLH: D2 as an LHP flag write
    wrnz_n   : out std_logic                       -- Noise RAM host write strobe
  );
end entity;

architecture rtl of amy1_seq_commands is

  -- step-level: the T10MHZ flip-flops (master, slave)
  signal m1_reg, q1_reg, m2_reg, q2_reg : std_logic := '0';
  signal m1, q1, m2, q2 : std_logic;

  -- chip-clock registers
  signal rst_reg,    rst_next    : std_logic := '0';
  signal run_reg,    run_next    : std_logic := '0';   -- SFTRSTN: SC0 (SEQRUN)
  signal nzreq_reg,  nzreq_next  : std_logic := '0';   -- LOADNZ: SC1
  signal sftd_reg,   sftd_next   : std_logic := '0';   -- not SEQRUN, taken at SYNC
  signal nzinit_reg, nzinit_next : std_logic := '0';
  signal wrnzn_reg,  wrnzn_next  : std_logic := '0';

  signal run, nzreq : std_logic;
  signal c_d2, c_scr, c_sor : std_logic;

begin

  -- T10MHZ flip-flops: q1 follows RESETN, q2 follows q1 (q = not reset)
  m1 <= resetn when t10 = '0' else m1_reg;
  q1 <= m1_reg when t10 = '1' else q1_reg;
  m2 <= q1     when t10 = '0' else m2_reg;
  q2 <= m2_reg when t10 = '1' else q2_reg;

  -- decodes
  c_d2   <= busy and cmnd(7) and not cmnd(6);
  c_scr  <= '1' when busy = '1' and seqb2 = '1' and cmnd(7 downto 4) = "0011" else '0';
  c_sor  <= '1' when busy = '1' and seqb2 = '1' and cmnd(7 downto 4) = "0010" else '0';
  d2     <= c_d2;
  rdha   <= busy and cmnd(7) and cmnd(6);
  wrha   <= busy and not cmnd(7) and cmnd(6);
  rdff   <= '1' when busy = '1' and cmnd(7 downto 3) = "00011" else '0';
  wrff   <= '1' when busy = '1' and cmnd(7 downto 3) = "00001" else '0';
  wrffnz <= '1' when busy = '1' and cmnd(7 downto 3) = "00010" else '0';
  ld_scr <= c_scr;
  ld_sor <= c_sor;

  -- the SCR bits, cleared while in reset
  run   <= run_reg and not rst_reg;
  nzreq <= nzreq_reg and not rst_reg;

  process (q2, c_scr, cmnd, run, nzreq, sync, sftd_reg, nzinit_reg, p2, c_d2)
  begin
    rst_next <= not q2;
    run_next   <= run;
    nzreq_next <= nzreq;
    if c_scr = '1' then
      run_next   <= cmnd(0);
      nzreq_next <= cmnd(1);
    end if;
    sftd_next   <= sftd_reg;
    nzinit_next <= nzinit_reg;
    if sync = '1' then
      sftd_next   <= not run;
      nzinit_next <= nzreq;
    end if;
    wrnzn_next <= not (p2 and c_d2 and nzreq and nzinit_reg);
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if step_en = '1' then
        m1_reg <= m1; q1_reg <= q1; m2_reg <= m2; q2_reg <= q2;
      end if;
      if tick = '1' then
        rst_reg    <= rst_next;
        run_reg    <= run_next;
        nzreq_reg  <= nzreq_next;
        sftd_reg   <= sftd_next;
        nzinit_reg <= nzinit_next;
        wrnzn_reg  <= wrnzn_next;
      end if;
    end if;
  end process;

  rst    <= rst_reg;
  clrph  <= sftd_reg or not run or rst_reg;
  nzinit <= nzinit_reg;
  wr_lhp <= not nzreq and c_d2;
  wrnz_n <= wrnzn_reg;

end architecture;
