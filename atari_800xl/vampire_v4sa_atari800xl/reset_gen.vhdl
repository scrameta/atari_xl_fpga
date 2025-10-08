library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use IEEE.STD_LOGIC_MISC.all;

-- Reset generator for Atari core + DDR3 Qsys EMIF
-- Inputs:
--   pll_pal_locked        : raw PAL PLL lock (1 = locked)
--   pll_ntsc_locked       : raw NTSC PLL lock (1 = locked)   -- if unused, tie to '0'
--   clk_atari             : your core/user clock
--   ddr3ip_local_init_done: from Qsys EMIF (alien clock domain!)
--   ddrpll_pll_locked     : EMIF/DDR PLL lock (1 = locked)
--
-- Outputs (all active-low):
--   atari_reset_n         : core reset (async assert, sync deassert; waits for DDR init_done)
--   softreset_reset_n     : feed to EMIF softreset_n_reset_n (filtered DDR lock)
--   reset_reset_n         : feed to Qsys reset_n_reset_n (fabric side in your clk_atari domain)

entity reset_gen is
  generic (
    CORE_LOCK_STABLE_CYCLES : natural := 4096;  -- cycles of clk_atari
    EMIF_LOCK_STABLE_CYCLES : natural := 65536  -- cycles of clk_atari (only used for filtering)
  );
  port (
    -- Inputs
    pll_pal_locked         : in  std_logic;
    pll_ntsc_locked        : in  std_logic;
    clk_atari              : in  std_logic;
    ddr3ip_local_init_done : in  std_logic; -- async to clk_atari
    ddrpll_pll_locked      : in  std_logic;

    -- Outputs (active-low)
    atari_reset_n          : out std_logic;
    softreset_reset_n      : out std_logic;
    reset_reset_n          : out std_logic
  );
end entity;

architecture rtl of reset_gen is

  -- Combine PAL/NTSC locks for the core domain
  signal core_pll_lock          : std_logic;

  -- Simple digital filters (stretchers) for lock signals
  function clog2(n : natural) return natural is
    variable i : natural := 0;
    variable v : natural := 1;
  begin
    while v < n loop
      v := v * 2;
      i := i + 1;
    end loop;
    return i;
  end;

  constant CORE_CNT_W : natural := clog2(CORE_LOCK_STABLE_CYCLES);
  constant EMIF_CNT_W : natural := clog2(EMIF_LOCK_STABLE_CYCLES);

  signal core_lock_cnt   : unsigned(CORE_CNT_W-1 downto 0) := (others => '0');
  signal core_lock_ok    : std_logic := '0';

  signal emif_lock_cnt   : unsigned(EMIF_CNT_W-1 downto 0) := (others => '0');
  signal emif_lock_ok    : std_logic := '0';

  -- Synchronizer for EMIF status into clk_atari
  signal emif_init_done_meta : std_logic := '0';
  signal emif_init_done_sync : std_logic := '0';

  -- Core reset synchronizer (async assert, sync deassert)
  signal rst_sync_ddr3 : std_logic_vector(1 downto 0) := (others => '0');
  signal rst_sync_atari : std_logic_vector(1 downto 0) := (others => '0');

begin

  ---------------------------------------------------------------------------
  -- 1) Core PLL lock combine + filter (in clk_atari domain)
  ---------------------------------------------------------------------------
  core_pll_lock <= pll_pal_locked or pll_ntsc_locked;

  process(clk_atari)
  begin
    if rising_edge(clk_atari) then
      if core_pll_lock = '0' then
        core_lock_cnt <= (others => '0');
        core_lock_ok  <= '0';
      elsif core_lock_ok = '0' then
        if and_reduce(std_logic_vector(core_lock_cnt))='1' then
          core_lock_ok <= '1';
        else
          core_lock_cnt <= core_lock_cnt + 1;
        end if;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- 2) DDR EMIF PLL lock filter (re-used in clk_atari domain for simplicity)
  --    This just creates a clean, slowly-releasing soft reset for EMIF.
  ---------------------------------------------------------------------------
  process(clk_atari)
  begin
    if rising_edge(clk_atari) then
      if ddrpll_pll_locked = '0' then
        emif_lock_cnt <= (others => '0');
        emif_lock_ok  <= '0';
      elsif emif_lock_ok = '0' then
        if and_reduce(std_logic_vector(emif_lock_cnt))='1' then
          emif_lock_ok <= '1';
        else
          emif_lock_cnt <= emif_lock_cnt + 1;
        end if;
      end if;
    end if;
  end process;

  -- Active-low reset into EMIF softreset_n_reset_n port
  softreset_reset_n <= emif_lock_ok;  -- 1 = release reset once DDR PLL is stably locked

  ---------------------------------------------------------------------------
  -- 3) Synchronize EMIF init_done into clk_atari domain (2-FF)
  ---------------------------------------------------------------------------
  process(clk_atari)
  begin
    if rising_edge(clk_atari) then
      emif_init_done_meta <= ddr3ip_local_init_done;  -- async input!
      emif_init_done_sync <= emif_init_done_meta;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- 4) Core reset (async assert on core PLL loss; sync deassert; wait for EMIF init)
  ---------------------------------------------------------------------------
  -- Asynchronous assertion condition: losing the core PLL lock should immediately assert reset
  -- Deassertion: only when core_lock_ok = '1' AND emif_init_done_sync = '1'
  process(clk_atari, core_lock_ok)
  begin
    if core_lock_ok = '0' then
      rst_sync_ddr3 <= "00";                        -- async assert
      rst_sync_atari <= "00";                        -- async assert
    elsif rising_edge(clk_atari) then
      if emif_init_done_sync = '1' then       -- gate release on DDR init_done (now synchronized)
        rst_sync_atari <= rst_sync_atari(0) & '1';        -- shift in ones to release over 2 cycles
      else
        rst_sync_atari <= "00";                     -- hold in reset until DDR ready
      end if;
      rst_sync_ddr3 <= rst_sync_ddr3(0) & '1';        -- shift in ones to release over 2 cycles
    end if;
  end process;

  atari_reset_n <= rst_sync_atari(1);
  reset_reset_n <= rst_sync_ddr3(1);  -- same reset for Qsys fabric in clk_atari domain -> except we must not wait for init_done

  ---------------------------------------------------------------------------
  -- Notes:
  -- * If you prefer the core to come out of reset BEFORE DDR is ready (and just gate traffic),
  --   replace the deassert block with: rst_sync <= rst_sync(0) & '1';  -- unconditionally
  --   (i.e., remove the emif_init_done_sync gating).
  --
  -- * All outputs are active-low as requested.
  -- * ddr3ip_local_init_done is treated as asynchronous and synchronized with 2 FFs.
  -- * softreset_reset_n intentionally does NOT depend on init_done (no chicken-egg).
  ---------------------------------------------------------------------------

end architecture;

