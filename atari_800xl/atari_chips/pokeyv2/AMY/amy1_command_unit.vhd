-------------------------------------------------------------------------------
-- AMY1 command unit: reset, the command handshake, decode, SCR and SOR, INT/RDY,
-- read-back loads. See AMY1_SPEC.md 4.7.
--
-- Reset: the reset input, registered.
-- Handshake: writing the command register sets a request; it passes two registers (SEQ1D,
-- SEQB2), and SEQB2 sets busy and clears the request. busy (and its copy one clock later)
-- gates the decode. The command ends when its write or read-back has happened (or at once
-- for SCR and SOR); busy clears two clocks later. A command written in clock n is busy
-- from clock n+2.
-- INT/RDY: READY mode = no command pending or running; INT mode = the end-of-command
-- pulse.
-- Decode (while busy), into cmd:
--   11hhhhhh read harmonic   01hhhhhh write harmonic breakpoint   10hhhhhh LHP flag
--   (SC1 = 0) or Noise RAM (SC1 = 1)   00011vvv read frequency   00001vvv write frequency
--   breakpoint   00010vvv write voice type   0011xxxx SCR   0010xxxx SOR
-- SCR: bit 0 run, bit 1 NZINIT request; they take effect at SYNC. SOR: bit 1 INT mode,
-- bit 2 INDIVIDUAL mode, bit 3 40 harmonics (bit 0, ALE mode, has no pins here).
-- Read-back: C is loaded at P3 and B at P1 of the following slot.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.amy1_pkg.all;

entity amy1_command_unit is
  port (
    clk       : in  std_logic;
    ce        : in  std_logic;                     -- chip clock enable: registers update
    reset     : in  std_logic;                     -- RESET (active high)
    -- host interface
    cmnd      : in  std_logic_vector(7 downto 0);  -- command register
    cmd_wr    : in  std_logic;                     -- the host wrote it (one clk)
    -- timebase
    p         : in  std_logic_vector(0 to 3);
    sync      : in  std_logic;
    upd_freq  : in  std_logic;
    -- the command's write has happened
    env_wr    : in  std_logic;                     -- envelope RAM host write
    noise_wr  : in  std_logic;                     -- Noise RAM host write
    -- outputs
    rst       : out std_logic;
    config    : out config_t;
    cmd       : out host_cmd_t;
    ld_rb     : out std_logic;                     -- read-back: load B at the end of this clock
    ld_rc     : out std_logic;                     -- read-back: load C at the end of this clock
    rdy       : out std_logic                      -- INT/RDY
  );
end entity;

architecture rtl of amy1_command_unit is

  -- the request (set by a command write at any clk)
  signal req_reg : std_logic := '0';
  signal req : std_logic;

  -- chip-clock registers
  signal rst_reg,    rst_next    : std_logic := '0';
  signal seq1d_reg,  seq1d_next  : std_logic := '0';
  signal seqb2_reg,  seqb2_next  : std_logic := '0';
  signal bset_reg,   bset_next   : std_logic := '0';   -- busy latch state
  signal bsy1d_reg,  bsy1d_next  : std_logic := '0';
  signal endd_reg,   endd_next   : std_logic := '0';   -- end of command one clock late
  signal endd2_reg,  endd2_next  : std_logic := '0';   -- two clocks late: clears busy
  signal run_reg,    run_next    : std_logic := '0';   -- SCR bit 0
  signal nzreq_reg,  nzreq_next  : std_logic := '0';   -- SCR bit 1
  signal stop_reg,   stop_next   : std_logic := '0';   -- not run, taken at SYNC
  signal nzinit_reg, nzinit_next : std_logic := '0';   -- NZINIT request, taken at SYNC
  signal sor_reg,    sor_next    : std_logic_vector(3 downto 1) := (others => '0');
  signal rdfa1_reg,  rdfa1_next  : std_logic := '0';   -- read-back, from P1
  signal rdfa2_reg,  rdfa2_next  : std_logic := '0';   -- one clock later

  signal bs, bsy, busy, run, nzreq, d2, rd_harm, rd_freq, ld_scr, ld_sor, rdfa, ldrb, endc : std_logic;
  signal sor : std_logic_vector(3 downto 1);
  signal op  : host_op_t;

begin

  -----------------------------------------------------------------------------
  -- handshake
  -----------------------------------------------------------------------------
  req <= req_reg and not rst_reg and not seqb2_reg;   -- a command waits

  -- busy: an SR latch, set by SEQB2, cleared by reset and the end of the command
  bs   <= seqb2_reg or (bset_reg and not rst_reg and not endd2_reg);
  bsy  <= bs and not rst_reg and not endd2_reg;
  busy <= bsy and bsy1d_reg;

  -----------------------------------------------------------------------------
  -- decode
  -----------------------------------------------------------------------------
  run   <= run_reg and not rst_reg;
  nzreq <= nzreq_reg and not rst_reg;
  sor   <= sor_reg and not (3 downto 1 => rst_reg);

  d2      <= busy and cmnd(7) and not cmnd(6);
  rd_harm <= busy and cmnd(7) and cmnd(6);
  rd_freq <= '1' when busy = '1' and cmnd(7 downto 3) = "00011" else '0';
  ld_scr  <= '1' when busy = '1' and seqb2_reg = '1' and cmnd(7 downto 4) = "0011" else '0';
  ld_sor  <= '1' when busy = '1' and seqb2_reg = '1' and cmnd(7 downto 4) = "0010" else '0';

  op <= OP_NONE     when busy = '0' else
        OP_RD_HARM  when cmnd(7 downto 6) = "11" else
        OP_WR_HARM  when cmnd(7 downto 6) = "01" else
        OP_WR_NOISE when cmnd(7 downto 6) = "10" and nzreq = '1' else
        OP_WR_LHP   when cmnd(7 downto 6) = "10" else
        OP_RD_FREQ  when cmnd(7 downto 3) = "00011" else
        OP_WR_FREQ  when cmnd(7 downto 3) = "00001" else
        OP_WR_TYPE  when cmnd(7 downto 3) = "00010" else
        OP_NONE;

  -- read-back: from P1 (a frequency read waits for a period without the voice's update)
  rdfa <= not rdfa1_reg and ((not upd_freq and rd_freq) or rd_harm);
  ldrb <= p(1) and rdfa2_reg;

  -- the command is done
  endc <= ld_sor or ld_scr or noise_wr or ldrb or env_wr;

  process (reset, req, seq1d_reg, bs, bsy, endc, endd_reg, ld_scr, cmnd, run, nzreq, sync, stop_reg,
           nzinit_reg, ld_sor, sor, p, rdfa, rdfa1_reg)
  begin
    rst_next   <= reset;
    seq1d_next <= req;
    seqb2_next <= seq1d_reg;
    bset_next  <= bs;
    bsy1d_next <= bsy;
    endd_next  <= endc;
    endd2_next <= endd_reg;
    run_next   <= run;
    nzreq_next <= nzreq;
    if ld_scr = '1' then
      run_next   <= cmnd(0);
      nzreq_next <= cmnd(1);
    end if;
    stop_next   <= stop_reg;
    nzinit_next <= nzinit_reg;
    if sync = '1' then
      stop_next   <= not run;
      nzinit_next <= nzreq;
    end if;
    sor_next <= sor;
    if ld_sor = '1' then
      sor_next <= cmnd(3 downto 1);
    end if;
    rdfa1_next <= rdfa1_reg;
    if p(1) = '1' then
      rdfa1_next <= rdfa;
    end if;
    rdfa2_next <= rdfa1_reg;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if ce = '1' and (seqb2_reg = '1' or rst_reg = '1') then
        req_reg <= '0';
      elsif cmd_wr = '1' then
        req_reg <= '1';
      end if;
      if ce = '1' then
        rst_reg    <= rst_next;
        seq1d_reg  <= seq1d_next;
        seqb2_reg  <= seqb2_next;
        bset_reg   <= bset_next;
        bsy1d_reg  <= bsy1d_next;
        endd_reg   <= endd_next;
        endd2_reg  <= endd2_next;
        run_reg    <= run_next;
        nzreq_reg  <= nzreq_next;
        stop_reg   <= stop_next;
        nzinit_reg <= nzinit_next;
        sor_reg    <= sor_next;
        rdfa1_reg  <= rdfa1_next;
        rdfa2_reg  <= rdfa2_next;
      end if;
    end if;
  end process;

  rst <= rst_reg;

  config.nzinit     <= nzinit_reg;
  config.clrph      <= stop_reg or not run or rst_reg;
  config.int_mode   <= sor(1);
  config.individual <= sor(2);
  config.sel40      <= sor(3);

  cmd.op    <= op;
  cmd.harm  <= cmnd(5 downto 1) & (cmnd(0) and not (d2 and not nzreq));
  cmd.voice <= cmnd(2 downto 0);
  cmd.word  <= cmnd(4);
  cmd.lhp   <= cmnd(0);

  ld_rb   <= (p(1) or p(2)) and rdfa2_reg;
  ld_rc   <= (p(3) or p(0)) and rdfa1_reg;
  -- READY: no command pending or running; INT: the end-of-command pulse
  rdy     <= (not (req_reg or seq1d_reg or bsy) and not sor(1)) or (endd2_reg and sor(1));

end architecture;
