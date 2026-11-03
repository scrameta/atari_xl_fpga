-------------------------------------------------------------------------------
-- AMY1 host interface: pins, the internal bus IB, the command and A/B/C registers,
-- the system option register
--
-- Behavioural rewrite of the BUS schematic block, see AMY1_SPEC.md 4.8.
--
-- Host registers (A1 A0, with CSN):          IB, the internal 8-bit bus, is precharged
--   0 write  command register (CMND)         high; every enabled source pulls its 0 bits
--   1 r/w    register A (data)               low (a wired AND). Sources: the data pins
--   2 r/w    register B (5 bits)             (write cycle), register A (read, or ENSLP:
--   3 r/w    register C                      the envelope takes A during a command), B, C
-- (read 0 gives FF).                         (reads), the envelope read-back (EN7RDBKH/L)
--                                            and the test outputs (TST1: exp ROM, TST2: slope).
-- The registers are latches, transparent while written; B and C are also loaded from IB
-- by the read-back (LDRB, LDRC). B and C together are the AUX word to the envelope.
-- SOR (system option register, command 0010xxxx): bit 0 ALE mode, 1 INT (not READY) mode,
-- 2 SUM mode (inverted: SUMMODEN), 3 SEL40H; cleared by reset.
-- ALE mode: the address comes from DB1..0, latched while ALE is high. The ALE pad is
-- an output (the chip clock) outside ALE mode and is not modelled as an input: in ALE
-- mode it keeps its last value.
-- The data pads keep their charge when nobody drives them.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity amy1_host_interface is
  port (
    clk          : in  std_logic;
    step_en      : in  std_logic;                     -- one step
    tick         : in  std_logic;                     -- chip clock: registers update
    clk_ph       : in  std_logic;
    rst          : in  std_logic;
    -- pins
    pin_a        : in  std_logic_vector(1 downto 0);
    pin_csn      : in  std_logic;
    pin_rdn      : in  std_logic;
    pin_wrn      : in  std_logic;
    pin_db_in    : in  std_logic_vector(7 downto 0);
    pin_db_drive : in  std_logic;                     -- the host drives DB
    pin_db_out   : out std_logic_vector(7 downto 0);
    pin_db_oe    : out std_logic_vector(7 downto 0);
    pin_resetn, pin_test, pin_oen : in std_logic;
    resetn, test, oen : out std_logic;
    -- sequencer
    ld_sor       : in  std_logic;
    ld_rb, ld_rc : in  std_logic;                     -- read-back: IB into B, C
    en_slp       : in  std_logic;                     -- register A onto IB
    tst1, tst2   : in  std_logic;
    -- read-back and test sources
    en7h, en7l   : in  std_logic;                     -- EN7RDBKH, EN7RDBKL
    rb_hi        : in  std_logic_vector(4 downto 0);
    rb_lo        : in  std_logic_vector(7 downto 0);
    rb_slope     : in  std_logic_vector(7 downto 0);
    xo           : in  std_logic_vector(7 downto 0);  -- exp ROM output (TST1)
    -- outputs
    cmnd         : out std_logic_vector(7 downto 0);
    ld_cmnd      : out std_logic;
    ib           : out std_logic_vector(7 downto 0);
    aux          : out std_logic_vector(12 downto 0); -- B & C
    nrin         : out std_logic_vector(2 downto 0);  -- Noise RAM host data
    rdyn         : out std_logic;
    sum_n        : out std_logic;                     -- SUMMODEN
    sel40        : out std_logic                      -- SEL40H
  );
end entity;

architecture rtl of amy1_host_interface is

  -- step-level state: the latches and the pads' charge
  signal db_reg   : std_logic_vector(7 downto 0) := (others => '0');
  signal cmnd_reg : std_logic_vector(7 downto 0) := (others => '0');
  signal a_reg    : std_logic_vector(7 downto 0) := (others => '0');
  signal b_reg    : std_logic_vector(4 downto 0) := (others => '0');
  signal c_reg    : std_logic_vector(7 downto 0) := (others => '0');
  signal ia_l_reg : std_logic_vector(1 downto 0) := (others => '0');   -- ALE address latch
  signal ale_reg  : std_logic := '0';

  -- chip-clock register: SOR
  signal sor_reg, sor_next : std_logic_vector(3 downto 0) := (others => '0');

  signal sor  : std_logic_vector(3 downto 0);
  signal db, ib_i, cmnd_i, a_i, c_i : std_logic_vector(7 downto 0);
  signal b_i  : std_logic_vector(4 downto 0);
  signal ia_l, ia : std_logic_vector(1 downto 0);
  signal ale, ale_mode, rd, wr, din, dout : std_logic;
  signal wr0, rd1, wr1, rd2, wr2, rd3, wr3, sel_a, wr_b, wr_c : std_logic;

begin

  -- SOR bits, cleared while in reset
  sor      <= sor_reg and not (3 downto 0 => rst);
  ale_mode <= sor(0);

  -- address
  ale  <= clk_ph when ale_mode = '0' else ale_reg;
  ia_l <= db_reg(1 downto 0) when (ale and ale_mode) = '1' else ia_l_reg;
  ia   <= ia_l when ale_mode = '1' else pin_a;

  rd   <= not pin_csn and not pin_rdn;
  wr   <= not pin_csn and not pin_wrn;
  din  <= wr;
  dout <= rd;
  wr0  <= wr when ia = "00" else '0';
  rd1  <= rd when ia = "01" else '0';
  wr1  <= wr when ia = "01" else '0';
  rd2  <= rd when ia = "10" else '0';
  wr2  <= wr when ia = "10" else '0';
  rd3  <= rd when ia = "11" else '0';
  wr3  <= wr when ia = "11" else '0';
  sel_a <= rd1 or en_slp;
  wr_b  <= wr2 or ld_rb;
  wr_c  <= wr3 or ld_rc;

  -- IB: the wired AND of the enabled sources (latches read with their last-step value)
  process (din, db_reg, sel_a, a_reg, rd2, b_reg, rd3, c_reg, tst1, xo, tst2, rb_slope,
           en7l, rb_lo, en7h, rb_hi)
    variable v : std_logic_vector(7 downto 0);
  begin
    v := (others => '1');
    if din = '1'   then v := v and db_reg;   end if;
    if sel_a = '1' then v := v and a_reg;    end if;
    if rd2 = '1'   then v(4 downto 0) := v(4 downto 0) and b_reg; end if;
    if rd3 = '1'   then v := v and c_reg;    end if;
    if tst1 = '1'  then v := v and xo;       end if;
    if tst2 = '1'  then v := v and rb_slope; end if;
    if en7l = '1'  then v := v and rb_lo;    end if;
    if en7h = '1'  then v(4 downto 0) := v(4 downto 0) and rb_hi; end if;
    ib_i <= v;
  end process;

  -- the latches
  cmnd_i <= ib_i when wr0 = '1' else cmnd_reg;
  a_i    <= ib_i when wr1 = '1' else a_reg;
  b_i    <= ib_i(4 downto 0) when wr_b = '1' else b_reg;
  c_i    <= ib_i when wr_c = '1' else c_reg;

  -- data pads
  db <= ib_i when dout = '1' else pin_db_in when pin_db_drive = '1' else db_reg;

  -- SOR: loaded from the command register
  sor_next <= cmnd_i(3 downto 0) when ld_sor = '1' else sor;

  process (clk)
  begin
    if rising_edge(clk) then
      if step_en = '1' then
        db_reg   <= db;
        cmnd_reg <= cmnd_i;
        a_reg    <= a_i;
        b_reg    <= b_i;
        c_reg    <= c_i;
        ia_l_reg <= ia_l;
        ale_reg  <= ale;
      end if;
      if tick = '1' then
        sor_reg <= sor_next;
      end if;
    end if;
  end process;

  pin_db_out <= db;
  pin_db_oe  <= (others => dout);
  resetn <= pin_resetn;
  test   <= pin_test;
  oen    <= pin_oen;

  -- the sequencer reads the command register one step after the latch: it decodes it
  -- only after the load has ended (this also keeps the read-back enables, which come
  -- from the decode, out of a loop through IB)
  cmnd    <= cmnd_reg;
  ld_cmnd <= wr0;
  ib      <= ib_i;
  aux     <= b_i & c_i;
  nrin    <= ib_i(2 downto 0);
  rdyn    <= sor(1);
  sum_n   <= sor(2);
  sel40   <= sor(3);

end architecture;
