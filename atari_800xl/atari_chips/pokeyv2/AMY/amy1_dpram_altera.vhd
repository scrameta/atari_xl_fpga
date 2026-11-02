---------------------------------------------------------------------------
-- True dual-port RAM for the AMY ROM pairs: one M9K, port A read/write,
-- port B read only, one clock, both ports' address registers enabled by EN.
-- Port B reads the OLD data when port A writes the same word at the same edge
-- (the NOISE RAM in M9K 2 relies on this).
-- Quartus version: altsyncram instantiated directly (inference split the
-- ports into two copies). Use amy1_dpram_sim.vhd for simulation instead.
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
library altera_mf;
use altera_mf.altera_mf_components.all;

entity amy1_dpram is
  generic (
    AW : natural;
    DW : natural
  );
  port (
    clk    : in  std_logic;
    en     : in  std_logic;
    we_a   : in  std_logic;
    addr_a : in  std_logic_vector(AW - 1 downto 0);
    data_a : in  std_logic_vector(DW - 1 downto 0);
    q_a    : out std_logic_vector(DW - 1 downto 0);
    addr_b : in  std_logic_vector(AW - 1 downto 0);
    q_b    : out std_logic_vector(DW - 1 downto 0)
  );
end entity;

architecture altera of amy1_dpram is
begin
  ram: altsyncram
    generic map (
      operation_mode                     => "BIDIR_DUAL_PORT",
      intended_device_family             => "MAX 10",
      lpm_type                           => "altsyncram",
      ram_block_type                     => "M9K",
      width_a                            => DW,
      widthad_a                          => AW,
      numwords_a                         => 2 ** AW,
      width_b                            => DW,
      widthad_b                          => AW,
      numwords_b                         => 2 ** AW,
      width_byteena_a                    => 1,
      width_byteena_b                    => 1,
      outdata_reg_a                      => "UNREGISTERED",
      outdata_reg_b                      => "UNREGISTERED",
      outdata_aclr_a                     => "NONE",
      outdata_aclr_b                     => "NONE",
      address_reg_b                      => "CLOCK0",
      indata_reg_b                       => "CLOCK0",
      wrcontrol_wraddress_reg_b          => "CLOCK0",
      clock_enable_input_a               => "NORMAL",
      clock_enable_input_b               => "NORMAL",
      clock_enable_output_a              => "BYPASS",
      clock_enable_output_b              => "BYPASS",
      power_up_uninitialized             => "FALSE",
      read_during_write_mode_mixed_ports => "OLD_DATA",
      read_during_write_mode_port_a      => "NEW_DATA_NO_NBE_READ",
      read_during_write_mode_port_b      => "NEW_DATA_NO_NBE_READ"
    )
    port map (
      clock0    => clk,
      clocken0  => en,
      wren_a    => we_a,
      address_a => addr_a,
      data_a    => data_a,
      q_a       => q_a,
      wren_b    => '0',
      address_b => addr_b,
      data_b    => (others => '0'),
      q_b       => q_b
    );
end architecture;
