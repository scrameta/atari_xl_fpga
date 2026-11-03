-------------------------------------------------------------------------------
-- AMY1 sequencer, page 19: test mode and the three output/test pads
--
-- Behavioural rewrite of SEQCONT page 19, see AMY1_SPEC.md 4.7.
--
-- The TEST pin selects test mode. In normal mode three pads are outputs:
--   OUTSTBN/T1   the output strobe
--   V0/T0        voice 0 marker: INDIVIDUAL mode V0, SUM mode the NEWOUT latch (set
--                by the 40-harmonic period-end decode, cleared by SYNCD)
--   BOUT/CSYNC   the noise generator's serial sum
-- In test mode they are inputs (T0, T1, CSYNC); T0/T1 select the test modes TST0..2.
-- Undriven pads keep their charge (their last value). The netlist's clock generator
-- on this page is replaced by the core's step sequencer.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity amy1_seq_pads is
  port (
    clk        : in  std_logic;
    step_en    : in  std_logic;                     -- one step
    test       : in  std_logic;                     -- TEST pin
    outstb_n   : in  std_logic;                     -- OUTSTBN
    bout       : in  std_logic;                     -- noise serial sum
    v0         : in  std_logic;                     -- V0 (INDIVIDUAL mode voice 0 marker)
    end40      : in  std_logic;                     -- X159K19: the CLKN-latched period-end decode
    syncd      : in  std_logic;                     -- SYNC one clock later
    sum_n      : in  std_logic;                     -- SUMMODEN: INDIVIDUAL mode
    tst        : out std_logic;
    tst0       : out std_logic;
    tst1       : out std_logic;
    tst2       : out std_logic;
    pad_outstb : out std_logic;                     -- OUTSTBN/T1
    pad_v0     : out std_logic;                     -- V0/T0
    pad_bout   : out std_logic;                     -- BOUT/CSYNC
    v0_out     : out std_logic                      -- PREV0T0: what the V0 pad drives
  );
end entity;

architecture rtl of amy1_seq_pads is

  -- step-level state: the latch and the pads' charge
  signal newout_n_reg : std_logic := '0';   -- X158K19 (NEWOUT inverted)
  signal pads_reg     : std_logic_vector(2 downto 0) := (others => '0');

  signal newout_n : std_logic;
  signal prev0    : std_logic;
  signal pads     : std_logic_vector(2 downto 0);   -- 2 = OUTSTBN/T1, 1 = V0/T0, 0 = BOUT/CSYNC
  signal t0, t1   : std_logic;

begin

  -- NEWOUT: gate latch, set by end40, cleared by SYNCD
  newout_n <= (end40 or newout_n_reg) and not syncd;

  prev0 <= not newout_n when sum_n = '0' else v0;

  -- pads: driven in normal mode, keep their charge in test mode
  pads <= (outstb_n & prev0 & bout) when test = '0' else pads_reg;
  t1 <= pads(2);
  t0 <= pads(1);

  process (clk)
  begin
    if rising_edge(clk) then
      if step_en = '1' then
        newout_n_reg <= newout_n;
        pads_reg     <= pads;
      end if;
    end if;
  end process;

  tst  <= test;
  tst0 <= test and not t0;
  tst1 <= test and not t0 and t1;
  tst2 <= test and t0 and not t1;

  pad_outstb <= pads(2);
  pad_v0     <= pads(1);
  pad_bout   <= pads(0);
  v0_out     <= prev0;

end architecture;
