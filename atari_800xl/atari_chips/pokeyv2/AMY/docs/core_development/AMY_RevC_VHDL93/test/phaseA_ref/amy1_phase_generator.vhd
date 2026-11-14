-------------------------------------------------------------------------------
-- AMY1 phase generator: voice phases and the sine arguments of the harmonics
--
-- Behavioural rewrite of the PHASE schematic block (pages 12-13), see AMY1_SPEC.md 4.4.
--
-- Each voice has a 20-bit phase in the phase RAM (8 words). The sequencer pulses
-- ld_voice at the start of each voice's harmonics; then, one clock apart:
--   +1  read the voice's phase phi from the RAM
--   +2  phi' = phi + xo (xo is the voice's frequency increment at this clock);
--       the harmonic phase register h takes phi'
--   +3  write phi' back (the write strobe is a CLKN latch: steps 4, 5 .. 3)
-- After that the RAM is read again, so every second clock h += phi': h = k phi' for
-- harmonic k.
--
-- Each harmonic takes two clocks, a and b (sel_h alternates):
--   a  the sine argument is h, half a cycle on;  disp is added for the next b
--   b  the sine argument is the displaced phase made at a
-- disp is xo(17 downto 8) latched (cleared by clrdisp): in these clocks xo carries
-- the harmonic's amplitude, so the amplitude sets the angle between the two lookups,
-- whose sines the output accumulator adds.
-- Finally the bit-reversed harmonic number is added to the top 6 bits of every
-- argument, so the harmonics do not all start in phase.
--
-- clrph clears the harmonic phase register (HALT mode, see the spec).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity amy1_phase_generator is
  port (
    clk       : in  std_logic;
    tick      : in  std_logic;                      -- chip clock: registers update
    sample    : in  std_logic;                      -- end of CLKN
    clkn_ph   : in  std_logic;                      -- chip CLKN phase (write strobe latch)
    -- sequencer
    ld_voice  : in  std_logic;                      -- first clock of a voice (LDVOICE)
    voice     : in  std_logic_vector(2 downto 0);   -- the voice
    cnt       : in  std_logic_vector(5 downto 0);   -- harmonic counter (CNT6..1)
    clrph     : in  std_logic;                      -- clear the harmonic phase
    -- exp_rom
    xo        : in  std_logic_vector(17 downto 0);  -- frequency increment / amplitude
    clrdisp   : in  std_logic;                      -- no displacement this clock
    -- sine_rom
    arg       : out std_logic_vector(13 downto 0);  -- sine argument (SARG13..8, ARG7..0)
    -- phase RAM (synchronous read)
    ram_addr  : out std_logic_vector(2 downto 0);
    ram_we    : out std_logic;
    ram_wdata : out std_logic_vector(19 downto 0);
    ram_q     : in  std_logic_vector(19 downto 0)
  );
end entity;

architecture rtl of amy1_phase_generator is

  signal addr_reg,  addr_next  : std_logic_vector(2 downto 0) := (others => '0');
  signal ldv1_reg,  ldv1_next  : std_logic := '0';   -- ld_voice +1: read
  signal ldv2_reg,  ldv2_next  : std_logic := '0';   -- ld_voice +2: add the frequency
  signal ldv3_reg,  ldv3_next  : std_logic := '0';   -- ld_voice +3: write
  signal selb_reg,  selb_next  : std_logic := '0';   -- sel_h one clock late
  signal drive_reg, drive_next : std_logic := '0';   -- the bus carries h (no RAM read)
  signal h_reg,     h_next     : unsigned(19 downto 0) := (others => '0');  -- harmonic phase
  signal disp_reg,  disp_next  : unsigned(9 downto 0) := (others => '0');
  signal dsum_reg,  dsum_next  : unsigned(13 downto 0) := (others => '0');  -- displaced phase
  signal wr_hold_reg           : std_logic := '1';   -- write strobe latch (CLKN; netlist power-up: on)

  signal sel_h  : std_logic;              -- clock a: the argument is h
  signal h      : unsigned(19 downto 0);  -- h as seen (clrph)
  signal disp   : unsigned(9 downto 0);   -- disp as seen (clrdisp)
  signal bus_v  : unsigned(19 downto 0);  -- phase bus: RAM data or h
  signal sum    : unsigned(19 downto 0);
  signal wr_d   : std_logic;
  signal swap   : unsigned(13 downto 0);
  signal dsum   : unsigned(13 downto 0);
  signal a      : unsigned(13 downto 0);  -- argument before the harmonic offset
  signal ofs    : unsigned(5 downto 0);

begin

  sel_h <= not (ldv1_reg or selb_reg);
  h     <= h_reg when clrph = '0' else (others => '0');
  disp  <= disp_reg when clrdisp = '0' else (others => '0');

  -- phase bus: the RAM is read except while h is driven for the write
  bus_v <= h when drive_reg = '1' else unsigned(ram_q);

  -- the adder: phase + frequency at ld_voice +2, otherwise h + phase
  sum <= bus_v + unsigned("00" & xo) when ldv2_reg = '1' else
         bus_v + h;

  -- displacement: at a, disp + not(last displaced phase); at b, disp + h
  swap <= not dsum_reg when sel_h = '1' else h(19 downto 6);
  dsum <= swap + resize(disp, 14);

  -- the argument: at a, h half a cycle on; at b, not(displaced phase)
  a <= (not h(19)) & h(18 downto 6) when sel_h = '1' else not dsum_reg;

  -- bit-reversed harmonic number on the top 6 bits
  ofs <= unsigned'(cnt(0) & cnt(1) & cnt(2) & cnt(3) & cnt(4) & cnt(5));
  arg <= std_logic_vector(a(13 downto 8) + ofs) & std_logic_vector(a(7 downto 0));

  -- phase RAM
  wr_d      <= drive_reg and ldv3_reg;
  ram_addr  <= addr_reg;
  ram_we    <= wr_d when clkn_ph = '1' else wr_hold_reg;
  ram_wdata <= std_logic_vector(bus_v);

  process (ld_voice, voice, addr_reg, ldv1_reg, ldv2_reg, ldv3_reg, sel_h, h, sum,
           xo, dsum)
  begin
    addr_next <= addr_reg;
    if ld_voice = '1' then
      addr_next <= voice;
    end if;
    ldv1_next  <= ld_voice;
    ldv2_next  <= ldv1_reg;
    ldv3_next  <= ldv2_reg;
    selb_next  <= sel_h;
    drive_next <= ldv2_reg or ldv3_reg;
    h_next     <= h;
    if sel_h = '1' then
      h_next <= sum;
    end if;
    disp_next <= unsigned(xo(17 downto 8));
    dsum_next <= dsum;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if sample = '1' then
        wr_hold_reg <= wr_d;
      end if;
      if tick = '1' then
        addr_reg  <= addr_next;
        ldv1_reg  <= ldv1_next;
        ldv2_reg  <= ldv2_next;
        ldv3_reg  <= ldv3_next;
        selb_reg  <= selb_next;
        drive_reg <= drive_next;
        h_reg     <= h_next;
        disp_reg  <= disp_next;
        dsum_reg  <= dsum_next;
      end if;
    end if;
  end process;

end architecture;
