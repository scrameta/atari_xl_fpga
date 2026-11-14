-------------------------------------------------------------------------------
-- AMY1 noise generator: two band-limited noise generators sharing the Noise RAM
--
-- Behavioural rewrite of the NOISE schematic block (pages 10-11), see AMY1_SPEC.md 4.1.
--
-- Each generator is a random walk of the second order:
--   * three 15-bit pseudo-random registers (PRB A, B, C) give three random bits
--     ra, rb, rc per pass: the XOR of their taps (bits 14, 11, 6 and 0);
--   * the up/down counter (UD) steps by ra + rc - 2 rb, that is -2 .. +2;
--   * the noise value (VAL, "B" in the spec) adds the up/down counter: VAL += UD;
--   * the shift control word (SHIFT, "S") picks the bits of VAL that make the output
--     word: each selected bit is shifted into the output register, and at the end of
--     the pass the word is {VAL bit 11, the last 11 bits shifted in}.
-- Bandwidth and level are therefore set by the RAM contents the host loads.
--
-- Noise RAM: 32 rows x 2 generators x 3 bits, RAM address = row & not gen.
--   rows  0-14 : PRB A, B, C (column = register, bit i at row 14-i)
--   row  15    : (shift overflow, unused)
--   row  16    : the random bits of the last pass
--   rows 20-31 : UD (column A), VAL (column B), SHIFT (column C), LSB at row 20
-- Each sample period one generator is processed (odd picks it), one row per slot.
-- The arithmetic is bit-serial, LSB first, one bit per row:
--   P0  load the row address; while it still points at the previous row, the random
--       bits take that row's data if it is a tap row (0, 3, 8, 14)
--   P1  read the row; latch the two adder carries of the previous row
--   P3  write the row back (see wb_data); if its SHIFT bit is 1, shift the new VAL
--       bit into the output register
--
-- In host mode (NZINIT) the host owns the RAM: the address comes from hadr (loaded at
-- P2), the write strobe from host_we and the data from host_data.
--
-- Registers: each is one of the chip's two-phase registers (sampled at the end of
-- CLKN, shown from CLK). They all update on tick, the end of the step before CLK.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.amy1_pkg.all;

entity amy1_noise_generator is
  port (
    clk       : in  std_logic;
    tick      : in  std_logic;                     -- chip clock: registers update
    clk_ph    : in  std_logic;                     -- chip CLK phase (gates the RAM write)
    -- sequencer
    p         : in  std_logic_vector(0 to 3);      -- slot phase P0..P3
    sync      : in  std_logic;                     -- last slot of the sample period
    odd       : in  std_logic;                     -- generator of this sample period
    hadr      : in  std_logic_vector(5 downto 0);  -- harmonic address (row & gen in host mode)
    host_mode : in  std_logic;                     -- NZINIT: the host owns the Noise RAM
    cmd       : in  host_cmd_t;                    -- the host command
    host_data : in  std_logic_vector(2 downto 0);  -- host write data (A2..0)
    host_wr   : out std_logic;                     -- the host write is happening
    -- envelope generator
    noise_gen : in  std_logic;                     -- the voice's generator (voice type 2)
    mute      : in  std_logic;                     -- force the noise word to zero
    noise     : out std_logic_vector(11 downto 0); -- noise word, two's complement
    serial    : out std_logic;                     -- VAL adder sum (the BOUT pin)
    -- Noise RAM
    ram_addr  : out std_logic_vector(5 downto 0);
    ram_we    : out std_logic;
    ram_wdata : out std_logic_vector(2 downto 0);
    ram_q     : in  std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of amy1_noise_generator is

  -- a RAM word: (2) = column A, (1) = column B, (0) = column C
  subtype word3 is std_logic_vector(2 downto 0);
  constant COL_UD    : natural := 2;
  constant COL_VAL   : natural := 1;
  constant COL_SHIFT : natural := 0;

  function maj(a, b, c : std_logic) return std_logic is
  begin
    return (a and b) or (a and c) or (b and c);
  end function;

  signal row_reg,     row_next     : unsigned(4 downto 0) := (others => '0');  -- row address
  signal hgen_reg,    hgen_next    : std_logic := '0';   -- host address bit 0
  signal odd_reg,     odd_next     : std_logic := '0';   -- generator being processed
  signal data_reg,    data_next    : word3 := (others => '0');  -- this row
  signal prev_reg,    prev_next    : word3 := (others => '0');  -- previous row (the shift)
  signal rnd_reg,     rnd_next     : word3 := (others => '0');  -- random bits ra, rb, rc
  signal upper_reg,   upper_next   : std_logic := '0';   -- previous row >= 16
  signal first_reg,   first_next   : std_logic := '0';   -- previous row 0, 4, 16 or 20: LSB
  signal ud_c_reg,    ud_c_next    : std_logic := '0';   -- UD adder carry
  signal val_c_reg,   val_c_next   : std_logic := '0';   -- VAL adder carry
  signal out_sr_reg,  out_sr_next  : std_logic_vector(10 downto 0) := (others => '0');  -- output shift register
  signal word0_reg,   word0_next   : std_logic_vector(11 downto 0) := (others => '0');  -- gen 0 word
  signal word1_reg,   word1_next   : std_logic_vector(11 downto 0) := (others => '0');  -- gen 1 word
  signal sync1_reg,   sync1_next   : std_logic := '0';
  signal sync2_reg,   sync2_next   : std_logic := '0';
  signal host_reg,    host_next    : std_logic := '0';   -- host mode, one clock late
  signal hwr_reg,     hwr_next     : std_logic := '1';   -- host write (P2 of a Noise RAM write)

  signal rnd     : word3;                 -- random bits (cleared one clock after SYNC)
  signal still   : std_logic;             -- ra = rb = rc: step 0
  signal ud_op, ud_ci, ud_sum, ud_co    : std_logic;  -- UD += step
  signal val_ci, val_sum, val_co        : std_logic;  -- VAL += UD
  signal wb_data : word3;                 -- data written back
  signal we      : std_logic;
  signal gen     : std_logic;             -- generator accessed (RAM address bit 0 = not gen)
  signal word    : std_logic_vector(11 downto 0);

begin

  -----------------------------------------------------------------------------
  -- Bit-serial arithmetic for the current row
  -----------------------------------------------------------------------------
  rnd   <= rnd_reg when sync2_reg = '0' else "000";
  still <= '1' when rnd = "000" or rnd = "111" else '0';

  -- UD += ra + rc - 2 rb, formed as an operand word plus the carry-in at the LSB:
  --   rb = 1: operand -2 (LSB not rb = 0, upper bits rb = 1), carry-in maj = ra or rc
  --   rb = 0: operand +1 (LSB 1, upper bits 0),               carry-in maj = ra and rc
  --   ra = rb = rc: no step (operand and carry forced to 0)
  ud_op  <= (rnd(COL_VAL) xor first_reg) and not still;
  ud_ci  <= maj(rnd(2), rnd(1), rnd(0)) and not still when first_reg = '1' else
            ud_c_reg and not still;
  ud_sum <= data_reg(COL_UD) xor ud_op xor ud_ci;
  ud_co  <= maj(data_reg(COL_UD), ud_op, ud_ci);

  -- VAL += UD (the new UD bit)
  val_ci  <= val_c_reg and not first_reg;
  val_sum <= data_reg(COL_VAL) xor ud_sum xor val_ci;
  val_co  <= maj(data_reg(COL_VAL), ud_sum, val_ci);

  -- Write-back data, chosen by the previous row (upper_reg) and this row:
  --   previous row >= 16 (rows 17-31, 0): the arithmetic (UD, VAL, SHIFT unchanged)
  --   this row < 16 (rows 1-15):          the previous row (PRB shift)
  --   this row >= 16 (row 16):            the random bits
  -- (The previous row is still >= 16 at row 0, so row 0 gets the arithmetic and the
  -- PRBs never see their feedback: AMY1_SPEC.md Q3, repaired by NOISE_FIX.)
  wb_data <= ud_sum & val_sum & data_reg(COL_SHIFT) when upper_reg = '1' else
             rnd when row_reg(4) = '1' else
             prev_reg;

  -----------------------------------------------------------------------------
  -- Noise RAM: write at P3 (or the host strobe), steps 3, 4, 5 and the next 0
  -----------------------------------------------------------------------------
  we  <= hwr_reg and not clk_ph when host_mode = '1' else
         p(3)    and not clk_ph;
  gen <= hgen_reg when host_mode = '1' else odd_reg;

  ram_addr  <= std_logic_vector(row_reg) & not gen;
  ram_we    <= we;
  ram_wdata <= host_data when host_mode = '1' else wb_data;

  -----------------------------------------------------------------------------
  -- Next state
  -----------------------------------------------------------------------------
  process (row_reg, hgen_reg, data_reg, prev_reg, rnd, upper_reg, ud_c_reg, val_c_reg,
           out_sr_reg, word0_reg, word1_reg, odd_reg, sync1_reg, host_reg,
           p, sync, odd, hadr, host_mode, ram_q, ud_co, val_co, val_sum)
  begin
    row_next    <= row_reg;
    hgen_next   <= hgen_reg;
    data_next   <= data_reg;
    prev_next   <= prev_reg;
    rnd_next    <= rnd;
    upper_next  <= upper_reg;
    ud_c_next   <= ud_c_reg;
    val_c_next  <= val_c_reg;
    out_sr_next <= out_sr_reg;
    word0_next  <= word0_reg;
    word1_next  <= word1_reg;

    -- every clock
    odd_next   <= odd;
    sync1_next <= sync;
    sync2_next <= sync1_reg;
    host_next  <= host_mode;
    first_next <= '0';
    if row_reg(3) = '0' and row_reg(1) = '0' and row_reg(0) = '0' then
      first_next <= '1';
    end if;

    -- address: P0, or P2 in host mode
    if (host_mode = '0' and p(0) = '1') or (host_mode = '1' and p(2) = '1') then
      row_next  <= unsigned(hadr(5 downto 1));
      hgen_next <= hadr(0);
    end if;

    if p(0) = '1' then
      upper_next <= row_reg(4);
      -- PRB taps: rows 0, 3, 8, 14 = bits 14, 11, 6, 0 (the address is still the
      -- previous row's)
      if row_reg = 0 or row_reg = 3 or row_reg = 8 or row_reg = 14 then
        rnd_next <= rnd xor data_reg;
      end if;
    end if;

    if p(1) = '1' then
      data_next  <= ram_q;
      ud_c_next  <= ud_co;
      val_c_next <= val_co;
      if row_reg(4) = '0' then
        prev_next <= data_reg;
      end if;
    end if;

    -- SHIFT bit set: shift the new VAL bit into the output register
    if p(3) = '1' and data_reg(COL_SHIFT) = '1' then
      out_sr_next <= val_sum & out_sr_reg(10 downto 1);
    end if;

    -- output word at SYNC (not in host mode): VAL bit 11 and the last 11 bits shifted in
    if sync1_reg = '1' and host_reg = '0' then
      if odd_reg = '0' then
        word0_next <= val_sum & out_sr_reg;
      else
        word1_next <= val_sum & out_sr_reg;
      end if;
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if tick = '1' then
        hwr_reg <= hwr_next;
        row_reg    <= row_next;
        hgen_reg   <= hgen_next;
        odd_reg    <= odd_next;
        data_reg   <= data_next;
        prev_reg   <= prev_next;
        rnd_reg    <= rnd_next;
        upper_reg  <= upper_next;
        first_reg  <= first_next;
        ud_c_reg   <= ud_c_next;
        val_c_reg  <= val_c_next;
        out_sr_reg <= out_sr_next;
        word0_reg  <= word0_next;
        word1_reg  <= word1_next;
        sync1_reg  <= sync1_next;
        sync2_reg  <= sync2_next;
        host_reg   <= host_next;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Outputs
  -----------------------------------------------------------------------------
  word   <= word1_reg when noise_gen = '1' else word0_reg;
  noise  <= word when mute = '0' else (others => '0');
  serial <= val_sum;
  hwr_next <= '1' when p(2) = '1' and cmd.op = OP_WR_NOISE and host_mode = '1' else '0';
  host_wr  <= hwr_reg;

end architecture;
