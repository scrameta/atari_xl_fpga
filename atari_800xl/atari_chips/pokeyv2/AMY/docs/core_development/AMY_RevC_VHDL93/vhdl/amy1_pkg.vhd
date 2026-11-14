-------------------------------------------------------------------------------
-- AMY1 core: types shared between the units
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

package amy1_pkg is

  -- The host command being executed (decoded once, by the command unit).
  type host_op_t is (OP_NONE,
                     OP_RD_HARM,     -- 11hhhhhh  read harmonic amplitude      -> B:C
                     OP_WR_HARM,     -- 01hhhhhh  write harmonic breakpoint    <- A (slope), C (destination)
                     OP_WR_LHP,      -- 10hhhhhh  write Last Harmonic Pair flag (SC1 = 0) <- CMND0
                     OP_WR_NOISE,    -- 10aaaaaa  write Noise RAM (SC1 = 1)    <- A(2:0)
                     OP_RD_FREQ,     -- 00011vvv  read voice frequency         -> B:C
                     OP_WR_FREQ,     -- 00001vvv  write frequency breakpoint   <- A (slope), B:C (destination)
                     OP_WR_TYPE);    -- 00010vvv  write voice type             <- B:C

  type host_cmd_t is record
    op    : host_op_t;
    harm  : std_logic_vector(5 downto 0);   -- harmonic (LSB 0 for an LHP write: a pair)
    voice : std_logic_vector(2 downto 0);
    word  : std_logic;                      -- CMND4: the voice word
    lhp   : std_logic;                      -- CMND0: the LHP flag to write
  end record;

  -- Configuration from the SCR and SOR commands
  type config_t is record
    nzinit   : std_logic;   -- SCR bit 1, taken at SYNC: the host owns the Noise RAM
    clrph    : std_logic;   -- not running (SCR bit 0 = 0, taken at SYNC) or reset: phases cleared
    int_mode : std_logic;   -- SOR bit 1: INT/RDY is a pulse at the end of a command
    individual : std_logic; -- SOR bit 2: one sample per voice (INDIVIDUAL); 0: per period (SUM)
    sel40    : std_logic;   -- SOR bit 3: 40 harmonics
  end record;

end package;
