-------------------------------------------------------------------------------
-- AMY1 timebase: the clock, sample and voice counters, the slot phases, the voice and
-- sample strobes. See AMY1_SPEC.md 4.7.
--
-- Clock counter cnt (7 bits) counts the chip clocks of a sample period. Four clocks
-- P0..P3 (cnt(1:0) one clock late; reset forces P0) make a slot of two harmonics, so
-- cnt(6:2) is the slot. The period ends at clock 125 (64 harmonics) or 77 (40, SEL40H):
-- that decode clears the voice counter, and two clocks later sync restarts cnt and
-- advances the sample counter, so a period is 128 or 80 clocks.
-- Sample counter sam (7 bits): sam(0) = odd (ODDEV); ssen, the envelopes' slope enable,
-- is on every 2, 8, 32 or 128 samples by the slope rate.
-- Voice counter cntv (3 bits): advances at each last-harmonic-pair pulse, stops at 7.
-- new_voice marks a voice change (or the period end); voice is cntv taken at P1.
-- Strobes: zerob mutes the noise word from a new voice's P0 to P3; nv, ld_voice and
-- ld_flo follow. The sample is latched (ld_samp, P0) two slots after a voice load (every
-- voice in INDIVIDUAL mode, voice 0 in SUM mode); outstb follows two clocks later; v0
-- marks voice 0's sample in INDIVIDUAL mode.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_timebase is
  port (
    clk        : in  std_logic;
    ce         : in  std_logic;                     -- chip clock enable: registers update
    rst        : in  std_logic;
    sel40      : in  std_logic;                     -- 40 harmonics
    individual : in  std_logic;                     -- one sample per voice
    last_pair  : in  std_logic;                     -- the envelope saw a last harmonic pair flag
    slope_rate : in  std_logic_vector(1 downto 0);  -- of the envelope being stepped
    -- slot
    p          : out std_logic_vector(0 to 3);      -- slot phase P0..P3
    cnt        : out std_logic_vector(6 downto 0);  -- clock in the period (cnt(6:2) = slot)
    p2x        : out std_logic;                     -- P1 one clock late
    sync       : out std_logic;                     -- the period restarts
    odd        : out std_logic;                     -- odd sample period
    ssen       : out std_logic;                     -- step the envelope this period
    cntv       : out std_logic_vector(2 downto 0);  -- voice counter
    voice      : out std_logic_vector(2 downto 0);  -- the voice of this slot
    new_voice  : out std_logic;
    upd_freq   : out std_logic;                     -- the voice's frequency envelope is stepped
    -- strobes
    zerob      : out std_logic;                     -- mute the noise word
    nv         : out std_logic;                     -- zerob one clock later
    ld_voice   : out std_logic;
    ld_flo     : out std_logic;                     -- load the voice's low frequency bits and type
    ld_samp    : out std_logic;                     -- latch the sample
    outstb     : out std_logic;                     -- output strobe
    v0         : out std_logic                      -- INDIVIDUAL mode: voice 0's sample
  );
end entity;

architecture rtl of amy1_timebase is

  -- chip-clock registers
  signal cnt_reg,    cnt_next    : unsigned(6 downto 0) := (others => '0');
  signal sam_reg,    sam_next    : unsigned(6 downto 0) := (others => '0');
  signal cntv_reg,   cntv_next   : unsigned(2 downto 0) := (others => '0');
  signal voice_reg,  voice_next  : unsigned(2 downto 0) := (others => '0');
  signal endd_reg,   endd_next   : std_logic := '1';   -- period end one clock late
  signal end2_reg,   end2_next   : std_logic := '1';   -- two clocks late (powers up set: sync)
  signal p2x_reg,    p2x_next    : std_logic := '0';
  signal ph_reg,     ph_next     : std_logic_vector(0 to 3) := (others => '0');
  signal newvw_reg,  newvw_next  : std_logic := '0';   -- new voice, taken at P1
  signal nv_reg,     nv_next     : std_logic := '0';
  signal ldv_reg,    ldv_next    : std_logic := '1';   -- ld_voice
  signal ldvm1_reg,  ldvm1_next  : std_logic := '0';   -- sample voice, one slot late
  signal ldvm2_reg,  ldvm2_next  : std_logic := '0';   -- two slots late
  signal ls1_reg,    ls1_next    : std_logic := '1';   -- ld_samp one clock late
  signal ostb_reg,   ostb_next   : std_logic := '1';   -- outstb
  signal ostbn_reg,  ostbn_next  : std_logic := '0';   -- not outstb, one clock late
  signal c15_reg,    c15_next    : std_logic := '0';   -- clock 15 one clock late
  signal v0_reg,     v0_next     : std_logic := '0';

  -- the state of the two set/reset latches
  signal zerob_reg, x49_reg : std_logic := '0';
  signal zerob_i, x49, iv0, ldsamp_i : std_logic;

  signal sync_i, end_n, new40, lastv, newv_i : std_logic;

begin

  sync_i <= end2_reg or rst;

  -- period end (clrv_n low): 125, or 77 with SEL40H
  new40 <= '1' when cnt_reg = 77 and rst = '0' else '0';
  end_n <= '0' when (cnt_reg = 125 and rst = '0') or (new40 = '1' and sel40 = '1') else '1';

  -- voice
  lastv  <= '1' when last_pair = '1' and cntv_reg /= 7 else '0';
  newv_i <= lastv or not end_n;

  -- zerob: set from a new voice's P0 (or reset), cleared in P3
  zerob_i <= not ph_reg(3) and ((ph_reg(0) and newvw_reg) or zerob_reg or rst);

  -- sample strobe: in P0, two slots after the voice load
  ldsamp_i <= ph_reg(0) and ldvm2_reg;

  -- v0 (as the netlist: set while outstb has been off, cleared from clock 15)
  x49 <= not (ostbn_reg and not x49_reg) and not c15_reg;
  iv0 <= ostbn_reg and not x49;


  process (sync_i, cnt_reg, rst, sam_reg, end2_reg, end_n, cntv_reg, lastv, ph_reg,
           voice_reg, endd_reg, newvw_reg, newv_i, zerob_i, nv_reg, ldv_reg, individual, ldvm2_reg,
           ldvm1_reg, ldsamp_i, ls1_reg, ostb_reg, iv0)
    variable r0, r1 : std_logic;
  begin
    if sync_i = '1' then
      cnt_next <= (others => '0');
    else
      cnt_next <= cnt_reg + 1;
    end if;
    if rst = '1' then
      sam_next <= (others => '0');
    elsif end2_reg = '1' then
      sam_next <= sam_reg + 1;
    else
      sam_next <= sam_reg;
    end if;
    if rst = '1' or end_n = '0' then
      cntv_next <= (others => '0');
    elsif lastv = '1' then
      cntv_next <= cntv_reg + 1;
    else
      cntv_next <= cntv_reg;
    end if;
    voice_next <= voice_reg;
    if ph_reg(1) = '1' then
      voice_next <= cntv_reg;
    end if;
    endd_next <= not end_n;
    end2_next <= endd_reg;
    p2x_next  <= ph_reg(1);
    -- P0..P3 = cnt(1:0) one clock late; reset forces P0
    r0 := cnt_reg(0) or rst;
    r1 := cnt_reg(1) or rst;
    ph_next <= (r1 and r0) & (not r1 and not r0) & (not r1 and r0) & (r1 and not r0);
    newvw_next <= newvw_reg;
    if ph_reg(1) = '1' then
      newvw_next <= newv_i;
    end if;
    nv_next  <= zerob_i;
    ldv_next <= ph_reg(3) and nv_reg;
    ldvm1_next <= ldvm1_reg;
    ldvm2_next <= ldvm2_reg;
    if ph_reg(0) = '1' then
      if voice_reg = 0 or individual = '1' then
        ldvm1_next <= ldv_reg;
      else
        ldvm1_next <= '0';
      end if;
      ldvm2_next <= ldvm1_reg;
    end if;
    ls1_next   <= ldsamp_i;
    ostb_next  <= ls1_reg;
    ostbn_next <= not ostb_reg;
    c15_next   <= '0';
    if cnt_reg = 15 then
      c15_next <= '1';
    end if;
    v0_next    <= iv0;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if ce = '1' then
        zerob_reg <= zerob_i;
        x49_reg   <= x49;
        cnt_reg   <= cnt_next;
        sam_reg   <= sam_next;
        cntv_reg  <= cntv_next;
        voice_reg <= voice_next;
        endd_reg  <= endd_next;
        end2_reg  <= end2_next;
        p2x_reg   <= p2x_next;
        ph_reg    <= ph_next;
        newvw_reg <= newvw_next;
        nv_reg    <= nv_next;
        ldv_reg   <= ldv_next;
        ldvm1_reg <= ldvm1_next;
        ldvm2_reg <= ldvm2_next;
        ls1_reg   <= ls1_next;
        ostb_reg  <= ostb_next;
        ostbn_reg <= ostbn_next;
        c15_reg   <= c15_next;
        v0_reg    <= v0_next;
      end if;
    end if;
  end process;

  p         <= ph_reg;
  cnt       <= std_logic_vector(cnt_reg);
  p2x       <= p2x_reg;
  sync      <= sync_i;
  odd       <= sam_reg(0);
  ssen      <= '1' when (slope_rate = "11")
                     or (slope_rate = "10" and sam_reg(2 downto 1) = 0)
                     or (slope_rate = "01" and sam_reg(4 downto 1) = 0)
                     or (slope_rate = "00" and sam_reg(6 downto 1) = 0) else '0';
  cntv      <= std_logic_vector(cntv_reg);
  voice     <= std_logic_vector(voice_reg);
  new_voice <= newv_i;
  upd_freq  <= newv_i and (cntv_reg(0) xor sam_reg(0));
  zerob     <= zerob_i;
  nv        <= nv_reg;
  ld_voice  <= ldv_reg;
  ld_flo    <= ph_reg(3) and newvw_reg;
  ld_samp   <= ldsamp_i;
  outstb    <= ostb_reg;
  v0        <= v0_reg;

end architecture;
