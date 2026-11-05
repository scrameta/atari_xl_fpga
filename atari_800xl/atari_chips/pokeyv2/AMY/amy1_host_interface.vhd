-------------------------------------------------------------------------------
-- AMY1 host interface: the command register and registers A, B, C. See AMY1_SPEC.md 4.8.
--
--   addr   write             read
--   0      command (CMND)    FF
--   1      A (8 bits)        A
--   2      B (5 bits)        B (bits 7..5 read 1)
--   3      C (8 bits)        C
--
-- A synchronous port: we writes wdata at the clk edge; rdata is the addressed register.
-- A read command loads B and C from the envelope generator's read-back value (ld_rb,
-- ld_rc, at the end of the chip clock).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity amy1_host_interface is
  port (
    clk      : in  std_logic;
    ce       : in  std_logic;                     -- chip clock enable: read-back loads
    -- register port
    addr     : in  std_logic_vector(1 downto 0);
    we       : in  std_logic;
    wdata    : in  std_logic_vector(7 downto 0);
    rdata    : out std_logic_vector(7 downto 0);
    -- read-back
    ld_rb    : in  std_logic;
    ld_rc    : in  std_logic;
    readback : in  std_logic_vector(12 downto 0);
    -- registers
    cmnd     : out std_logic_vector(7 downto 0);
    cmd_wr   : out std_logic;                     -- the command register is being written
    reg_a    : out std_logic_vector(7 downto 0);
    reg_b    : out std_logic_vector(4 downto 0);
    reg_c    : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of amy1_host_interface is

  signal cmnd_reg, a_reg, c_reg : std_logic_vector(7 downto 0) := (others => '0');
  signal b_reg : std_logic_vector(4 downto 0) := (others => '0');

begin

  process (clk)
  begin
    if rising_edge(clk) then
      if we = '1' then
        case addr is
          when "00"   => cmnd_reg <= wdata;
          when "01"   => a_reg <= wdata;
          when "10"   => b_reg <= wdata(4 downto 0);
          when others => c_reg <= wdata;
        end case;
      end if;
      if ce = '1' and ld_rb = '1' then
        b_reg <= readback(12 downto 8);
      end if;
      if ce = '1' and ld_rc = '1' then
        c_reg <= readback(7 downto 0);
      end if;
    end if;
  end process;

  with addr select rdata <=
    a_reg         when "01",
    "111" & b_reg when "10",
    c_reg         when "11",
    x"FF"         when others;

  cmnd   <= cmnd_reg;
  cmd_wr <= we when addr = "00" else '0';
  reg_a  <= a_reg;
  reg_b  <= b_reg;
  reg_c  <= c_reg;

end architecture;
