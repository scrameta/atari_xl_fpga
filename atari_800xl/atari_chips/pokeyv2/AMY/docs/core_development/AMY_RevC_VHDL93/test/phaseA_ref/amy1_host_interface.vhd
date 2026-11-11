-------------------------------------------------------------------------------
-- AMY1 host interface: the command register and registers A, B, C. See AMY1_SPEC.md 4.8.
--
--   A1 A0   write             read
--   0       command (CMND)    FF
--   1       A (8 bits)        A
--   2       B (5 bits)        B (bits 7..5 read 1)
--   3       C (8 bits)        C
--
-- The registers are latches, transparent while the host writes them. A read command
-- loads B and C from the envelope generator's read-back value (ld_rb, ld_rc).
-- Phase A: still the chip's pin cycles (CSN, RDN, WRN, DB, with the pads' charge).
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity amy1_host_interface is
  port (
    clk          : in  std_logic;
    step_en      : in  std_logic;
    tick         : in  std_logic;                     -- chip clock: read-back loads
    -- pins
    pin_a        : in  std_logic_vector(1 downto 0);
    pin_csn      : in  std_logic;
    pin_rdn      : in  std_logic;
    pin_wrn      : in  std_logic;
    pin_db_in    : in  std_logic_vector(7 downto 0);
    pin_db_drive : in  std_logic;                     -- the host drives DB
    pin_db_out   : out std_logic_vector(7 downto 0);
    pin_db_oe    : out std_logic_vector(7 downto 0);
    -- read-back
    ld_rb, ld_rc : in  std_logic;
    readback     : in  std_logic_vector(12 downto 0);
    -- registers
    cmnd         : out std_logic_vector(7 downto 0);
    cmd_wr       : out std_logic;                     -- the host is writing the command
    reg_a        : out std_logic_vector(7 downto 0);
    reg_b        : out std_logic_vector(4 downto 0);
    reg_c        : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of amy1_host_interface is

  -- step-level: the latches and the data pads' charge
  signal db_reg   : std_logic_vector(7 downto 0) := (others => '0');
  signal cmnd_reg : std_logic_vector(7 downto 0) := (others => '0');
  signal a_reg    : std_logic_vector(7 downto 0) := (others => '0');
  signal b_reg    : std_logic_vector(4 downto 0) := (others => '0');
  signal c_reg    : std_logic_vector(7 downto 0) := (others => '0');

  signal rd, wr : std_logic;
  signal wr_r : std_logic_vector(0 to 3);
  signal db, din, rdata, cmnd_i, a_i, c_i : std_logic_vector(7 downto 0);
  signal b_i : std_logic_vector(4 downto 0);

begin

  rd <= not pin_csn and not pin_rdn;
  wr <= not pin_csn and not pin_wrn;
  process (wr, pin_a)
  begin
    wr_r <= (others => '0');
    case pin_a is
      when "00"   => wr_r(0) <= wr;
      when "01"   => wr_r(1) <= wr;
      when "10"   => wr_r(2) <= wr;
      when others => wr_r(3) <= wr;
    end case;
  end process;

  -- write data: the pads, one step late (as the chip's input buffers)
  din <= db_reg;

  -- the latches (B and C also take the read-back at the tick)
  cmnd_i <= din when wr_r(0) = '1' else cmnd_reg;
  a_i    <= din when wr_r(1) = '1' else a_reg;
  b_i    <= din(4 downto 0) when wr_r(2) = '1' else
            readback(12 downto 8) when tick = '1' and ld_rb = '1' else b_reg;
  c_i    <= din when wr_r(3) = '1' else
            readback(7 downto 0) when tick = '1' and ld_rc = '1' else c_reg;

  -- read data (the latches' last-step value)
  with pin_a select rdata <=
    a_reg         when "01",
    "111" & b_reg when "10",
    c_reg         when "11",
    x"FF"         when others;

  -- data pads: the read data, else the host's, else their charge
  db <= rdata when rd = '1' else pin_db_in when pin_db_drive = '1' else db_reg;

  process (clk)
  begin
    if rising_edge(clk) then
      if step_en = '1' then
        db_reg   <= db;
        cmnd_reg <= cmnd_i;
        a_reg    <= a_i;
        b_reg    <= b_i;
        c_reg    <= c_i;
      end if;
    end if;
  end process;

  pin_db_out <= db;
  pin_db_oe  <= (others => rd);

  cmnd   <= cmnd_i;
  cmd_wr <= wr_r(0);
  reg_a  <= a_i;
  reg_b  <= b_i;
  reg_c  <= c_i;

end architecture;
