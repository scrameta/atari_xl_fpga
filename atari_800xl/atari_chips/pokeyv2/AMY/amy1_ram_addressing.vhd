-------------------------------------------------------------------------------
-- AMY1 RAM addressing: the harmonic and voice RAM addresses. See AMY1_SPEC.md 4.7.
--
-- Harmonic RAMs (and the Noise RAM row in host mode): the slot's harmonic, cnt(6:2) and
-- the LSB halsb (odd harmonic: P0, and P2 of odd periods), or, in P2 of a host harmonic
-- command, the command's harmonic.
-- Voice RAMs: the voice counter and the word (not P2X), or the command's voice and word
-- (P1 of a frequency read outside the voice's update, P3 of a voice write).
-- The addresses are logical (the netlist drives the RAMs' address lines inverted).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.amy1_pkg.all;

entity amy1_ram_addressing is
  port (
    clk        : in  std_logic;
    ce         : in  std_logic;                     -- chip clock enable: registers update
    -- timebase
    p          : in  std_logic_vector(0 to 3);
    cnt        : in  std_logic_vector(6 downto 2);  -- slot
    p2x        : in  std_logic;
    odd        : in  std_logic;
    cntv       : in  std_logic_vector(2 downto 0);
    upd_freq   : in  std_logic;
    -- command
    cmd        : in  host_cmd_t;
    -- addresses
    harm_addr  : out std_logic_vector(5 downto 0);
    voice_addr : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of amy1_ram_addressing is

  signal halsb_reg, halsb_next : std_logic := '0';
  signal vcmd_reg,  vcmd_next  : std_logic := '0';   -- VFRECYC: the command's voice
  signal hcmd, p2y : std_logic;

begin

  hcmd <= '1' when cmd.op = OP_RD_HARM or cmd.op = OP_WR_HARM or cmd.op = OP_WR_LHP or
                   cmd.op = OP_WR_NOISE else '0';

  -- P2 of a host harmonic command
  p2y <= hcmd and p2x;

  halsb_next <= p(0) or (odd and p(2));
  vcmd_next  <= '1' when (cmd.op = OP_RD_FREQ and upd_freq = '0' and p(1) = '1') or
                         (p(3) = '1' and (cmd.op = OP_WR_FREQ or cmd.op = OP_WR_TYPE)) else '0';

  process (clk)
  begin
    if rising_edge(clk) then
      if ce = '1' then
        halsb_reg <= halsb_next;
        vcmd_reg  <= vcmd_next;
      end if;
    end if;
  end process;

  harm_addr  <= cmd.harm when p2y = '1' else cnt & halsb_reg;
  voice_addr <= (cmd.voice & not cmd.word) when vcmd_reg = '1' else cntv & p2x;

end architecture;
