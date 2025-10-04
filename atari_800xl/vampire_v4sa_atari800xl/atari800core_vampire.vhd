LIBRARY ieee;
USE ieee.std_logic_1164.all; 
use ieee.numeric_std.all;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_MISC.all;

LIBRARY work;

ENTITY atari800core_vampire IS 
	PORT
	(
		CLK0 : IN STD_LOGIC;
		CLK1 : IN STD_LOGIC;

		-- DDR3L
		DRAM_DQ : INOUT STD_LOGIC_VECTOR(15 downto 0);
		DRAM_A : OUT STD_LOGIC_VECTOR(15 downto 0);
		DRAM_BA : OUT STD_LOGIC_VECTOR(2 downto 0);
		DRAM_UDQS : INOUT STD_LOGIC;
		DRAM_UDQS_N : INOUT STD_LOGIC;
		DRAM_LDQS : INOUT STD_LOGIC;
		DRAM_LDQS_N : INOUT STD_LOGIC;
		DRAM_UDM : OUT STD_LOGIC;
		DRAM_LDM : OUT STD_LOGIC;
		DRAM_RAS_N : OUT STD_LOGIC;
		DRAM_CAS_N : OUT STD_LOGIC;
		DRAM_CK : OUT STD_LOGIC;
		DRAM_CK_N : OUT STD_LOGIC;
		DRAM_ODT : OUT STD_LOGIC;
		DRAM_CKE : OUT STD_LOGIC;
		DRAM_CS_N : OUT STD_LOGIC;
		DRAM_WE_N : OUT STD_LOGIC;
		DRAM_RESET_N : OUT STD_LOGIC;
		DRAM_RZQ : IN STD_LOGIC;

		-- PCM5120A
		AUD_BCLK :  OUT  STD_LOGIC;
		AUD_DACLRCK :  OUT  STD_LOGIC;
		AUD_DACDAT :  OUT  STD_LOGIC;

		--Micro SD card
		SD_DAT2 : OUT STD_LOGIC;
		SD_DAT3 : OUT STD_LOGIC;
		SD_CMD  : OUT STD_LOGIC;
		SD_CLK  : OUT STD_LOGIC;
		SD_DAT0 : IN STD_LOGIC;
		SD_DAT1 : OUT STD_LOGIC;
		SD_CD   : IN STD_LOGIC;

		--Joystick
		-- Pins shared with CF ADDR/DATA, need to disable CF_DATA_OE_N and CF_ADDR_OE_N
		JOY_OE_N : OUT STD_LOGIC;

		JOY1 : IN STD_LOGIC_VECTOR(4 downto 1);
		JOY2 : IN STD_LOGIC_VECTOR(4 downto 1);
		JOY1BUTTON : IN STD_LOGIC_VECTOR(1 downto 0);
		JOY2BUTTON : IN STD_LOGIC_VECTOR(1 downto 0);

		--HDMI
		HDMI_D4P : OUT STD_LOGIC; 
		HDMI_D4N : OUT STD_LOGIC;
		HDMI_D3P : OUT STD_LOGIC;
		HDMI_D3N : OUT STD_LOGIC;
		HDMI_D2P : OUT STD_LOGIC;
		HDMI_D2N : OUT STD_LOGIC;
		HDMI_D1P : OUT STD_LOGIC;
		HDMI_D1N : OUT STD_LOGIC;
		HDMI_SCL : OUT STD_LOGIC;
		HDMI_SDA : OUT STD_LOGIC;
		HDMI_OE_N : OUT STD_LOGIC;

		--USB
		USB1_DP : INOUT STD_LOGIC; --KB
		USB1_DN : INOUT STD_LOGIC; --
		USB2_DP : INOUT STD_LOGIC; --Mouse
		USB2_DN : INOUT STD_LOGIC; --
		USB3_DP : INOUT STD_LOGIC; --Joy
		USB3_DN : INOUT STD_LOGIC; --

		--Ethernet
		ETH_MODE1 : OUT STD_LOGIC;
		ETH_MODE0 : OUT STD_LOGIC;
		ETH_CRS   : INOUT STD_LOGIC; --MODE2
		ETH_MDIO  : INOUT STD_LOGIC;
		ETH_MDC	  : OUT STD_LOGIC;
		ETH_RST_N : OUT STD_LOGIC;
		ETH_TXEN  : OUT STD_LOGIC;
		ETH_TXD0  : OUT STD_LOGIC;
		ETH_TXD1  : OUT STD_LOGIC;

		--Compact flash
		CF_40CS1   : OUT STD_LOGIC;
		CF_40CS0   : OUT STD_LOGIC;
		CF_44CS0   : OUT STD_LOGIC;
		CF_44CS1   : OUT STD_LOGIC;

		CF_READSTROBE : OUT STD_LOGIC;
		CF_WRITESTROBE : OUT STD_LOGIC;
		CF_IORDY : IN STD_LOGIC;
		CF_INTRQ : IN STD_LOGIC;

		CF_DATA_OE_N : OUT STD_LOGIC; -- IO Shared with joystick and CF_ADDR
		CF_DATA_DIR  : OUT STD_LOGIC;
		--CF_DATA    : INOUT STD_LOGIC_VECTOR(15 downto 0);
		CF_DATA      : INOUT STD_LOGIC_VECTOR(7 downto 1); --Others are SHARED! See Joystick section and qsf file

		CF_ADDR_OE_N: OUT STD_LOGIC; -- IO Shared with joystick and CF_DATA
		CF_ADDR_LE  : OUT STD_LOGIC;
		--CF_ADDR     : OUT STD_LOGIC_VECTOR(2 downto 0);

		--P20 GPIO
		--GPIO_P20 : INOUT STD_LOGIC_VECTOR(7 downto 2); --1 downto 0 is USB3

		--P21 GPIO
		GPIO_P21 : INOUT STD_LOGIC_VECTOR(7 downto 0);

		--P21 GPIO
		GPIO_P22 : INOUT STD_LOGIC_VECTOR(7 downto 0);

		--P13 GPIO/Clock port
		GPIO_P13_D : INOUT STD_LOGIC;
		GPIO_P13_C : INOUT STD_LOGIC;

		--LEDs
		LED_DISK : OUT STD_LOGIC;
		LED_POWER : OUT STD_LOGIC
	);
END atari800core_vampire;		
		
ARCHITECTURE vhdl OF atari800core_vampire IS
	--atari
	signal THROTTLE_COUNT_6502 : std_logic_vector(5 downto 0);
	signal AUDIO_L_PCM_SIGNED : std_logic_vector(15 downto 0);
	signal AUDIO_R_PCM_SIGNED : std_logic_vector(15 downto 0);
	signal AUDIO_L_PCM_UNSIGNED : std_logic_vector(15 downto 0);
	signal AUDIO_R_PCM_UNSIGNED : std_logic_vector(15 downto 0);	
	signal CONSOL_OPTION : std_logic;
	signal CONSOL_START : std_logic;
	signal CONSOL_SELECT : std_logic;
	signal PAL : std_logic;
	
	-- scandoubler
	signal half_scandouble_enable_reg : std_logic;
	signal half_scandouble_enable_next : std_logic;
	signal ATARI_COLOUR : std_logic_vector(7 downto 0);
	signal VIDEO_HS : std_logic;
	signal VIDEO_VS : std_logic;
	signal scanlines : std_logic;
	signal csync : std_logic;
	signal video_mode : std_logic_vector(2 downto 0);
	signal tmds_h : std_logic_vector(7 downto 0);
	signal tmds_l : std_logic_vector(7 downto 0);
	signal ddio_out : std_logic_vector(7 downto 0);
	
	-- pll
	signal clk_hdmi_in : std_logic;
	signal clk_pixel_in : std_logic;
	signal clk_atari : std_logic;
	signal clk_atari_pal : std_logic;
	signal clk_atari_ntsc : std_logic;
	signal clk_aud : std_logic;
	signal clk_refresh : std_logic;
	signal reset_n : std_logic;

component pll_pal is
	port (
		refclk   : in  std_logic := '0'; --  refclk.clk
		rst      : in  std_logic := '0'; --   reset.reset
		outclk_0 : out std_logic;        -- outclk0.clk
		locked   : out std_logic         --  locked.export
	);
end component pll_pal;

component pll_ntsc is
	port (
		refclk   : in  std_logic := '0'; --  refclk.clk
		rst      : in  std_logic := '0'; --   reset.reset
		outclk_0 : out std_logic;        -- outclk0.clk
		locked   : out std_logic         --  locked.export
	);
end component pll_ntsc;
	
component clkctrl_pal_ntsc is
		 port (
					inclk3x   : in  std_logic                    := 'X';             -- inclk3x
					inclk2x   : in  std_logic                    := 'X';             -- inclk2x
					inclk1x   : in  std_logic                    := 'X';             -- inclk1x
					inclk0x   : in  std_logic                    := 'X';             -- inclk0x
					clkselect : in  std_logic_vector(1 downto 0) := (others => 'X'); -- clkselect
					ena       : in  std_logic                    := 'X';             -- ena
					outclk    : out std_logic                                        -- outclk
		 );
end component clkctrl_pal_ntsc;

component pll2
	port (
		refclk   : in  std_logic := '0'; --  refclk.clk
		rst      : in  std_logic := '0'; --   reset.reset
		outclk_0 : out std_logic;        -- outclk0.clk
		outclk_1 : out std_logic;        -- outclk1.clk
		locked   : out std_logic         --  locked.export
	);
end component;

component pll_usb is
	port (
		refclk   : in  std_logic := '0'; --  refclk.clk
		rst      : in  std_logic := '0'; --   reset.reset
		outclk_0 : out std_logic;        -- outclk0.clk
		outclk_1 : out std_logic;        -- outclk1.clk
		locked   : out std_logic         --  locked.export
	);
end component;

component pll_aud is
	port (
		refclk   : in  std_logic := '0'; --  refclk.clk
		rst      : in  std_logic := '0'; --   reset.reset
		outclk_0 : out std_logic;        -- outclk0.clk
		locked   : out std_logic         --  locked.export
	);
end component;


component sfl is
	port (
		asmi_access_granted : in  std_logic                    := '0';             -- asmi_access_granted.asmi_access_granted
		asmi_access_request : out std_logic;                                       -- asmi_access_request.asmi_access_request
		data_in             : in  std_logic_vector(3 downto 0) := (others => '0'); --             data_in.data_in
		data_oe             : in  std_logic_vector(3 downto 0) := (others => '0'); --             data_oe.data_oe
		data_out            : out std_logic_vector(3 downto 0);                    --            data_out.data_out
		dclk_in             : in  std_logic                    := '0';             --             dclk_in.dclkin
		ncso_in             : in  std_logic                    := '0';             --             ncso_in.scein
		noe_in              : in  std_logic                    := '0'              --              noe_in.noe
	);
end component;

signal pll_locked_pal: std_logic;
signal pll_locked_ntsc: std_logic;
signal pll_locked: std_logic;

signal ddr3ip_waitrequest        : std_logic;
signal ddr3ip_addr               : std_logic_vector(26 downto 0);
signal ddr3ip_rdata_valid        : std_logic;
signal ddr3ip_rdata              : std_logic_vector(31 downto 0);
signal ddr3ip_wdata              : std_logic_vector(31 downto 0);
signal ddr3ip_be                 : std_logic_vector(3 downto 0);
signal ddr3ip_read_req           : std_logic;
signal ddr3ip_write_req          : std_logic;
signal ddr3ip_local_init_done    : std_logic;
signal ddr3ip_local_cal_success  : std_logic;
signal ddr3ip_local_cal_fail     : std_logic;
signal ddr3ip_burstcount         : std_logic_vector(0 downto 0);

signal ram_state_next : std_logic_vector(1 downto 0);
signal ram_state_reg : std_logic_vector(1 downto 0);

constant ram_state_waitrequest : std_logic_vector(1 downto 0) := "00";
constant ram_state_waitwrite : std_logic_vector(1 downto 0) := "01";
constant ram_state_waitread : std_logic_vector(1 downto 0) := "10";
constant ram_state_waitreadvalid : std_logic_vector(1 downto 0) := "11";

	component ddr3 is
		port (
			clkatari_clk                     : in    std_logic                     := 'X';             -- clk
			ddrext_mem_a                     : out   std_logic_vector(14 downto 0);                    -- mem_a
			ddrext_mem_ba                    : out   std_logic_vector(2 downto 0);                     -- mem_ba
			ddrext_mem_ck                    : out   std_logic_vector(0 downto 0);                     -- mem_ck
			ddrext_mem_ck_n                  : out   std_logic_vector(0 downto 0);                     -- mem_ck_n
			ddrext_mem_cke                   : out   std_logic_vector(0 downto 0);                     -- mem_cke
			ddrext_mem_cs_n                  : out   std_logic_vector(0 downto 0);                     -- mem_cs_n
			ddrext_mem_dm                    : out   std_logic_vector(1 downto 0);                     -- mem_dm
			ddrext_mem_ras_n                 : out   std_logic_vector(0 downto 0);                     -- mem_ras_n
			ddrext_mem_cas_n                 : out   std_logic_vector(0 downto 0);                     -- mem_cas_n
			ddrext_mem_we_n                  : out   std_logic_vector(0 downto 0);                     -- mem_we_n
			ddrext_mem_reset_n               : out   std_logic;                                        -- mem_reset_n
			ddrext_mem_dq                    : inout std_logic_vector(15 downto 0) := (others => 'X'); -- mem_dq
			ddrext_mem_dqs                   : inout std_logic_vector(1 downto 0)  := (others => 'X'); -- mem_dqs
			ddrext_mem_dqs_n                 : inout std_logic_vector(1 downto 0)  := (others => 'X'); -- mem_dqs_n
			ddrext_mem_odt                   : out   std_logic_vector(0 downto 0);                     -- mem_odt
			ddrint_waitrequest               : out   std_logic;                                        -- waitrequest
			ddrint_readdata                  : out   std_logic_vector(31 downto 0);                    -- readdata
			ddrint_readdatavalid             : out   std_logic;                                        -- readdatavalid
			ddrint_burstcount                : in    std_logic_vector(0 downto 0)  := (others => 'X'); -- burstcount
			ddrint_writedata                 : in    std_logic_vector(31 downto 0) := (others => 'X'); -- writedata
			ddrint_address                   : in    std_logic_vector(26 downto 0) := (others => 'X'); -- address
			ddrint_write                     : in    std_logic                     := 'X';             -- write
			ddrint_read                      : in    std_logic                     := 'X';             -- read
			ddrint_byteenable                : in    std_logic_vector(3 downto 0)  := (others => 'X'); -- byteenable
			ddrint_debugaccess               : in    std_logic                     := 'X';             -- debugaccess
			ddroct_rzqin                     : in    std_logic                     := 'X';             -- rzqin
			ddrpll_pll_mem_clk               : out   std_logic;                                        -- pll_mem_clk
			ddrpll_pll_write_clk             : out   std_logic;                                        -- pll_write_clk
			ddrpll_pll_locked                : out   std_logic;                                        -- pll_locked
			ddrpll_pll_write_clk_pre_phy_clk : out   std_logic;                                        -- pll_write_clk_pre_phy_clk
			ddrpll_pll_addr_cmd_clk          : out   std_logic;                                        -- pll_addr_cmd_clk
			ddrpll_pll_avl_clk               : out   std_logic;                                        -- pll_avl_clk
			ddrpll_pll_config_clk            : out   std_logic;                                        -- pll_config_clk
			ddrpll_pll_mem_phy_clk           : out   std_logic;                                        -- pll_mem_phy_clk
			ddrpll_afi_phy_clk               : out   std_logic;                                        -- afi_phy_clk
			ddrpll_pll_avl_phy_clk           : out   std_logic;                                        -- pll_avl_phy_clk
			ddrrefclk_clk                    : in    std_logic                     := 'X';             -- clk
			ddrstatus_local_init_done        : out   std_logic;                                        -- local_init_done
			ddrstatus_local_cal_success      : out   std_logic;                                        -- local_cal_success
			ddrstatus_local_cal_fail         : out   std_logic;                                        -- local_cal_fail
			reset_n_reset_n                  : in    std_logic                     := 'X';             -- reset_n
			softreset_n_reset_n              : in    std_logic                     := 'X';              -- reset_n
         ddrrefresh_local_refresh_req     : in    std_logic                     := 'X';             -- local_refresh_req
         ddrrefresh_local_refresh_chip    : in    std_logic_vector(0 downto 0)  := (others => 'X'); -- local_refresh_chip
			ddrrefresh_local_refresh_ack     : out   std_logic;                                         -- local_refresh_ack			
			refresh_clk_clk                  : out   std_logic                                        -- refresh_clk.clk
		);
	end component ddr3;


	signal SDRAM_REQUEST : std_logic;
	signal SDRAM_REQUEST_COMPLETE : std_logic;
	signal SDRAM_READ_ENABLE :  STD_LOGIC;
	signal SDRAM_WRITE_ENABLE : std_logic;
	signal SDRAM_ADDR : STD_LOGIC_VECTOR(22 DOWNTO 0);
	signal SDRAM_ADDR_NEXT : STD_LOGIC_VECTOR(22 DOWNTO 0);
	signal SDRAM_ADDR_REG : STD_LOGIC_VECTOR(22 DOWNTO 0);
	signal SDRAM_DI : STD_LOGIC_VECTOR(31 DOWNTO 0);
	signal SDRAM_DO : STD_LOGIC_VECTOR(31 DOWNTO 0);
	signal SDRAM_WIDTH_8bit_ACCESS : std_logic;
	signal SDRAM_WIDTH_16bit_ACCESS : std_logic;
	signal SDRAM_WIDTH_32bit_ACCESS : std_logic;
	
	signal SDRAM_REFRESH : std_logic;
	signal SDRAM_REFRESH_STATE_NEXT : std_logic_vector(1 downto 0);
	signal SDRAM_REFRESH_STATE_REG : std_logic_vector(1 downto 0);
	constant SDRAM_REFRESH_STATE_WAITLOW : std_logic_vector(1 downto 0) := "00";
	constant SDRAM_REFRESH_STATE_WAITHIGH : std_logic_vector(1 downto 0) := "01";
	constant SDRAM_REFRESH_STATE_REQUESTHIGH : std_logic_vector(1 downto 0) := "10";
	signal SDRAM_REFRESH_REQUEST : std_logic;
	
	signal SDRAM_REFRESH_SYNC : std_logic;
	signal SDRAM_REFRESH_NEXT : std_logic;
	signal SDRAM_REFRESH_REG : std_logic;
	
	signal byteselo : std_logic_vector(7 downto 0);
	signal byteseli : std_logic_vector(7 downto 0);

	-- dma/virtual drive
	signal DMA_ADDR_FETCH : std_logic_vector(23 downto 0);
	signal DMA_WRITE_DATA : std_logic_vector(31 downto 0);
	signal DMA_FETCH : std_logic;
	signal DMA_32BIT_WRITE_ENABLE : std_logic;
	signal DMA_16BIT_WRITE_ENABLE : std_logic;
	signal DMA_8BIT_WRITE_ENABLE : std_logic;
	signal DMA_READ_ENABLE : std_logic;
	signal DMA_MEMORY_READY : std_logic;
	signal DMA_MEMORY_DATA : std_logic_vector(31 downto 0);

	signal ZPU_ADDR_ROM : std_logic_vector(15 downto 0);
	signal ZPU_ROM_DATA :  std_logic_vector(31 downto 0);

	signal ZPU_OUT1 : std_logic_vector(31 downto 0);
	signal ZPU_OUT2 : std_logic_vector(31 downto 0);
	signal ZPU_OUT3 : std_logic_vector(31 downto 0);
	signal ZPU_OUT4 : std_logic_vector(31 downto 0);
	signal ZPU_OUT5 : std_logic_vector(31 downto 0);
	signal ZPU_OUT6 : std_logic_vector(31 downto 0);

	signal zpu_pokey_enable : std_logic;
	signal zpu_sio_txd : std_logic;
	signal zpu_sio_rxd : std_logic;
	signal zpu_sio_command : std_logic;
	SIGNAL ASIO_CLOCKOUT : std_logic;

	-- system control from zpu
	signal ram_select : std_logic_vector(2 downto 0);
	signal reset_atari : std_logic;
	signal pause_atari : std_logic;
	SIGNAL speed_6502 : std_logic_vector(5 downto 0);
	signal turbo_vblank_only : std_logic;
	signal emulated_cartridge_select: std_logic_vector(5 downto 0);
	signal key_type : std_logic;
	signal atari800mode : std_logic;
	signal freezer_enable : std_logic;
	signal freezer_activate : std_logic;

	-- ps2
	signal PS2_KEYS : STD_LOGIC_VECTOR(511 downto 0);
	signal PS2_KEYS_NEXT : STD_LOGIC_VECTOR(511 downto 0);

	-- pokey keyboard
	SIGNAL KEYBOARD_SCAN : std_logic_vector(5 downto 0);
	SIGNAL KEYBOARD_RESPONSE : std_logic_vector(1 downto 0);
	signal atari_keyboard : std_logic_vector(63 downto 0);
	SIGNAL FKEYS : std_logic_vector(11 downto 0);

	-- usb
	signal CLK_USB : std_logic;

	signal USBWireVPin : std_logic_vector(2 downto 0);
	signal USBWireVMin : std_logic_vector(2 downto 0);
	signal USBWireVPout : std_logic_vector(2 downto 0);
	signal USBWireVMout : std_logic_vector(2 downto 0);
	signal USBWireOE_n : std_logic_vector(2 downto 0);

	-- spi flash
	signal spi_flash_select : std_logic;
	signal spi_flash_di : std_logic;
	signal spi_do : std_logic;
	signal spi_clk : std_logic;

BEGIN
	CF_DATA_OE_N <= '1';
	CF_ADDR_OE_N <= '1';
	JOY_OE_N <= '0';

	--GPIO_P20(2) <= b_reg(7);
	--GPIO_P20(4) <= VIDEO_VS;
	--GPIO_P20(6) <= VIDEO_HS;
	--GPIO_P20(3) <= clk_pixel_in;
	--GPIO_P20(5) <= clk_hdmi_in;
	--GPIO_P20(7) <= clk_atari;

	LED_DISK <= zpu_sio_txd;
	LED_POWER <= '0';

-- PLL
pll_pal_inst: pll_pal
port map (
	refclk		=> clk1,		-- 50.0 MHz

	-- out
	locked		=> pll_locked_pal,
	outclk_0	=> clk_atari_pal);

pll_ntsc_inst: pll_ntsc
port map (
	refclk		=> clk0,		-- 50.0 MHz

	-- out
	locked		=> pll_locked_ntsc,
	outclk_0	=> clk_atari_ntsc);	

clkctrl_pal_ntsc_inst : clkctrl_pal_ntsc
	 port map(
				inclk3x   => clk_atari_pal,
				inclk2x   => clk_atari_ntsc,
				clkselect(1) => '1',
				clkselect(0) => pal,
				ena => '1',
				outclk    => clk_atari
	 );
	
pll_locked <= pll_locked_pal and pll_locked_ntsc;	
	
pll2_inst: pll2
port map (
	refclk		=> clk1,		-- 50.0 MHz

	-- out
	locked		=> open,
	outclk_0	=> clk_hdmi_in,	-- clk_pixel_in * 5
	outclk_1	=> clk_pixel_in);
	
	

	-- Atari 800 core... With internal ROM/RAM.

atarixl_simple_sdram1 : entity work.atari800core_simple_sdram
	GENERIC MAP
	(
		cycle_length => 32,
		internal_rom => 1,
		internal_ram =>65536,
		video_bits => 8,
		palette => 0
	)
	PORT MAP
	(
		CLK => CLK_ATARI,
                RESET_N => RESET_N and not(reset_atari),

		VIDEO_VS => VIDEO_VS,
		VIDEO_HS => VIDEO_HS,
		VIDEO_B => ATARI_COLOUR,
		VIDEO_G => open,
		VIDEO_R => open,
		VIDEO_BLANK => open,
		VIDEO_BURST => open,
		VIDEO_START_OF_FIELD => open,
		VIDEO_ODD_LINE => open,

		AUDIO_L => AUDIO_L_PCM_SIGNED,
		AUDIO_R => AUDIO_R_PCM_SIGNED,

		JOY1_n(4) => JOY1BUTTON(0),
		JOY1_N(3 downto 0) => JOY1,
		JOY2_n(4) => JOY2BUTTON(0),
		JOY2_N(3 downto 0) => JOY2,

		KEYBOARD_RESPONSE => KEYBOARD_RESPONSE,
		KEYBOARD_SCAN => KEYBOARD_SCAN,

		SIO_COMMAND => zpu_sio_command,
		SIO_RXD => zpu_sio_txd,
		SIO_TXD => zpu_sio_rxd,
		SIO_CLOCKOUT => ASIO_CLOCKOUT,

		CONSOL_OPTION => CONSOL_OPTION,
		CONSOL_SELECT => CONSOL_SELECT,
		CONSOL_START => CONSOL_START,

		SDRAM_REQUEST => SDRAM_REQUEST,
		SDRAM_REQUEST_COMPLETE => SDRAM_REQUEST_COMPLETE,
		SDRAM_READ_ENABLE => SDRAM_READ_ENABLE,
		SDRAM_WRITE_ENABLE => SDRAM_WRITE_ENABLE,
		SDRAM_ADDR => SDRAM_ADDR,
		SDRAM_DO => SDRAM_DO,
		SDRAM_DI => SDRAM_DI,
		SDRAM_32BIT_WRITE_ENABLE => SDRAM_WIDTH_32bit_ACCESS,
		SDRAM_16BIT_WRITE_ENABLE => SDRAM_WIDTH_16bit_ACCESS,
		SDRAM_8BIT_WRITE_ENABLE => SDRAM_WIDTH_8bit_ACCESS,
		SDRAM_REFRESH => SDRAM_REFRESH,

		DMA_FETCH => dma_fetch,
		DMA_READ_ENABLE => dma_read_enable,
		DMA_32BIT_WRITE_ENABLE => dma_32bit_write_enable,
		DMA_16BIT_WRITE_ENABLE => dma_16bit_write_enable,
		DMA_8BIT_WRITE_ENABLE => dma_8bit_write_enable,
		DMA_ADDR => dma_addr_fetch,
		DMA_WRITE_DATA => dma_write_data,
		MEMORY_READY_DMA => dma_memory_ready,
		DMA_MEMORY_DATA => dma_memory_data, 

   		RAM_SELECT => ram_select,
		PAL => PAL,
		HALT => pause_atari,
		THROTTLE_COUNT_6502 => speed_6502,
		TURBO_VBLANK_ONLY => turbo_vblank_only,
		ATARI800MODE => atari800mode,
		emulated_cartridge_select => emulated_cartridge_select,
		freezer_enable => freezer_enable,
		freezer_activate => freezer_activate
	);

AUDIO_L_PCM_UNSIGNED <= not(AUDIO_L_PCM_SIGNED(15)) & AUDIO_L_PCM_SIGNED(14 downto 0);
AUDIO_R_PCM_UNSIGNED <= not(AUDIO_R_PCM_SIGNED(15)) & AUDIO_R_PCM_SIGNED(14 downto 0);
	
audio_codec_data : entity work.i2smaster
PORT MAP(CLK => CLK_AUD,
		RESET_N => RESET_N,
		 BCLK => AUD_BCLK,
		 DACLRC => AUD_DACLRCK,
		 LEFT_IN => AUDIO_L_PCM_SIGNED,
		 RIGHT_IN => AUDIO_R_PCM_SIGNED,
		 DACDAT => AUD_DACDAT);

	process(clk_atari,RESET_N,reset_atari)
	begin
		if ((RESET_N and not(reset_atari))='0') then
			half_scandouble_enable_reg <= '0';
		elsif (clk_atari'event and clk_atari='1') then
			half_scandouble_enable_reg <= half_scandouble_enable_next;
		end if;
	end process;

	half_scandouble_enable_next <= not(half_scandouble_enable_reg);

scandoubler_hdmi_int : work.scandoubler_hdmi
PORT MAP
( 
	CLK_ATARI_IN => CLK_ATARI,

	RESET_N => RESET_N, -- and not(reset_atari),

	audio_left => audio_l_pcm_unsigned,
	audio_right => audio_r_pcm_unsigned,
	
	-- GTIA interface
	pal => pal,
	scanlines_on => scanlines,
	csync_on => csync,
	format(0) => video_mode(2), --011 -> 10
	format(1) => video_mode(1), --100 -> 01
	colour_enable => half_scandouble_enable_reg,
	colour_in => ATARI_COLOUR,
	vsync_in => VIDEO_VS,
	hsync_in => VIDEO_HS,
	
	--HDMI clock domain
	clk_hdmi_in => clk_hdmi_in,
	CLK_PIXEL_IN => clk_pixel_in,

	O_hsync => open,
	O_vsync => open,
	O_blank => open,
	O_red => open,
	O_green => open,
	O_blue => open,

	-- TO TV...
	O_TMDS_H => tmds_h,
	O_TMDS_L => tmds_l
);

ddio_inst : entity work.altddio_out8
port map (
	datain_h => TMDS_H,
	datain_l => TMDS_L,
	outclock => clk_hdmi_in,
	dataout  => DDIO_OUT);

HDMI_D1P <= DDIO_OUT(6); -- D2P
HDMI_D1N <= DDIO_OUT(7); -- D2N
HDMI_D2P <= DDIO_OUT(4); -- D1P
HDMI_D2N <= DDIO_OUT(5); -- D1N
HDMI_D3P <= DDIO_OUT(2); -- D0P
HDMI_D3N <= DDIO_OUT(3); -- D0N
HDMI_D4P <= DDIO_OUT(0); -- C P
HDMI_D4N <= DDIO_OUT(1); -- C N
HDMI_OE_N <= '0';

-- DDR3
DRAM_A(15) <= '0';

ddr3_inst: ddr3
port map (
		   clkatari_clk                     => clk_atari,
			reset_n_reset_n                  => pll_locked,
			ddrext_mem_a                     => DRAM_A(14 downto 0),
			ddrext_mem_ba                    => DRAM_BA,
			ddrext_mem_ck(0)                 => DRAM_CK,
			ddrext_mem_ck_n(0)               => DRAM_CK_N,
			ddrext_mem_cke(0)                => DRAM_CKE,
			ddrext_mem_cs_n(0)               => DRAM_CS_N,
			ddrext_mem_dm(1)                 => DRAM_UDM,
			ddrext_mem_dm(0)                 => DRAM_LDM,
			ddrext_mem_ras_n(0)              => DRAM_RAS_N,
			ddrext_mem_cas_n(0)              => DRAM_CAS_N,
			ddrext_mem_we_n(0)               => DRAM_WE_N,
			ddrext_mem_reset_n               => DRAM_RESET_N,
			ddrext_mem_dq                    => DRAM_DQ,
			ddrext_mem_dqs(1)                => DRAM_UDQS,
			ddrext_mem_dqs(0)                => DRAM_LDQS,
			ddrext_mem_dqs_n(1)              => DRAM_UDQS_N,
			ddrext_mem_dqs_n(0)              => DRAM_LDQS_N,
			ddrext_mem_odt(0)                => DRAM_ODT,
			ddroct_rzqin                     => DRAM_RZQ,
			
			ddrint_waitrequest               => ddr3ip_waitrequest,
			ddrint_readdata                  => ddr3ip_rdata,
			ddrint_readdatavalid             => ddr3ip_rdata_valid,
			ddrint_burstcount                => ddr3ip_burstcount,
			ddrint_writedata                 => ddr3ip_wdata,
			ddrint_address                   => ddr3ip_addr,
			ddrint_write                     => ddr3ip_write_req,
			ddrint_read                      => ddr3ip_read_req,
			ddrint_byteenable                => ddr3ip_be,
			ddrint_debugaccess               => '0',	
			
			ddrrefclk_clk                    => clk0,
			
			ddrpll_pll_mem_clk               => open,
			ddrpll_pll_write_clk             => open,
			ddrpll_pll_locked                => reset_n,
			ddrpll_pll_write_clk_pre_phy_clk => open,
			ddrpll_pll_addr_cmd_clk          => open,
			ddrpll_pll_avl_clk               => open,
			ddrpll_pll_config_clk            => open,
			ddrpll_pll_mem_phy_clk           => open,
			ddrpll_afi_phy_clk               => open,
			ddrpll_pll_avl_phy_clk           => open,
			
			ddrstatus_local_init_done        => ddr3ip_local_init_done,
			ddrstatus_local_cal_success      => ddr3ip_local_cal_success,
			ddrstatus_local_cal_fail         => ddr3ip_local_cal_fail,
			softreset_n_reset_n              => reset_n,

			refresh_clk_clk => clk_refresh,
			
			ddrrefresh_local_refresh_req     => SDRAM_REFRESH_REG,
			ddrrefresh_local_refresh_chip    => "1",
			ddrrefresh_local_refresh_ack     => open
	);
	
	process(clk_atari,reset_n)
	begin
		if (reset_n='0') then
			ram_state_reg <= ram_state_waitrequest;
			SDRAM_ADDR_REG <= (OTHERS=>'0');
			SDRAM_REFRESH_STATE_REG <= SDRAM_REFRESH_STATE_WAITHIGH;
		elsif (clk_atari'event and clk_atari='1') then
			ram_state_reg <= ram_state_next;
			SDRAM_ADDR_REG <= SDRAM_ADDR_NEXT;
			SDRAM_REFRESH_STATE_REG <= SDRAM_REFRESH_STATE_NEXT;
		end if;
	end process;
	
	process(SDRAM_REFRESH_STATE_REG,SDRAM_REFRESH)
	begin
		SDRAM_REFRESH_STATE_NEXT <= SDRAM_REFRESH_STATE_REG;
		SDRAM_REFRESH_REQUEST <= '0';
		
		case SDRAM_REFRESH_STATE_REG is 
			when SDRAM_REFRESH_STATE_WAITHIGH =>
				if SDRAM_REFRESH='1' then
					SDRAM_REFRESH_STATE_NEXT <= SDRAM_REFRESH_STATE_REQUESTHIGH;
				end if;
			when SDRAM_REFRESH_STATE_REQUESTHIGH =>
				SDRAM_REFRESH_REQUEST <= '1';
				SDRAM_REFRESH_STATE_NEXT <= SDRAM_REFRESH_STATE_WAITLOW;
			when SDRAM_REFRESH_STATE_WAITLOW =>				
				if SDRAM_REFRESH='0' then
					SDRAM_REFRESH_STATE_NEXT <= SDRAM_REFRESH_STATE_WAITHIGH;
				end if;			
			when others =>
				SDRAM_REFRESH_STATE_NEXT <= SDRAM_REFRESH_STATE_WAITHIGH;
		end case;
	end process;

   refresh_synchronizer : entity work.synchronizer
			 port map (clk=>clk_refresh, raw=>SDRAM_REFRESH_REQUEST, sync=>SDRAM_REFRESH_SYNC);
	
	SDRAM_REFRESH_NEXT <= SDRAM_REFRESH_SYNC and not(SDRAM_REFRESH_REG);

	process(clk_refresh,reset_n)
	begin
		if (reset_n='0') then
			SDRAM_REFRESH_REG <= '0';
		elsif (clk_refresh'event and clk_refresh='1') then
			SDRAM_REFRESH_REG <= SDRAM_REFRESH_NEXT;
		end if;
	end process;	
	
	bytesel_o : entity work.bytesel
	port map(
		di => SDRAM_DI,
		sel => byteselo,
		do => ddr3ip_wdata
	);
	bytesel_i : entity work.bytesel
	port map(
		di => ddr3ip_rdata,
		sel => byteseli,
		do => SDRAM_DO
	);

	process(	
		ddr3ip_waitrequest,
		ddr3ip_rdata_valid,
		ram_state_reg,
		SDRAM_REQUEST,
		SDRAM_READ_ENABLE, SDRAM_WRITE_ENABLE,
		SDRAM_ADDR,
		SDRAM_ADDR_REG,
		SDRAM_ADDR_NEXT,
		SDRAM_DO,
		SDRAM_WIDTH_32bit_ACCESS, SDRAM_WIDTH_16bit_ACCESS, SDRAM_WIDTH_8bit_ACCESS
		)
	variable num_bits : std_logic_vector(2 downto 0);
	begin
		SDRAM_REQUEST_COMPLETE <= '0';

		SDRAM_ADDR_NEXT <= SDRAM_ADDR_REG;

		ddr3ip_addr(26 downto 21) <= (others=>'0');
		ddr3ip_addr(20 downto 0) <= SDRAM_ADDR_NEXT(22 downto 2);
		ddr3ip_read_req <= '0';
		ddr3ip_write_req <= '0';

		num_bits(0) := SDRAM_WIDTH_8bit_ACCESS;
		num_bits(1) := SDRAM_WIDTH_16bit_ACCESS;
		num_bits(2) := SDRAM_WIDTH_32bit_ACCESS;

		byteselo <= "11100100";
		byteseli <= "11100100";
		ddr3ip_be <= (others=>'1');

		-- Which bytes go where on output and input!
		case num_bits is
		when "001" =>
			byteselo <= "00000000";
--			byteseli(1 downto 0) <= not(SDRAM_ADDR_NEXT(1 downto 0));
--			ddr3ip_be(3) <= not(SDRAM_ADDR_NEXT(1)) and not(SDRAM_ADDR_NEXT(0));
--			ddr3ip_be(2) <= not(SDRAM_ADDR_NEXT(1)) and SDRAM_ADDR_NEXT(0);
--			ddr3ip_be(1) <= SDRAM_ADDR_NEXT(1) and not(SDRAM_ADDR_NEXT(0));
--			ddr3ip_be(0) <= SDRAM_ADDR_NEXT(1) and SDRAM_ADDR_NEXT(0);			
			
			byteseli(1 downto 0) <= SDRAM_ADDR_NEXT(1 downto 0);
			ddr3ip_be(0) <= not(SDRAM_ADDR_NEXT(1)) and not(SDRAM_ADDR_NEXT(0));
			ddr3ip_be(1) <= not(SDRAM_ADDR_NEXT(1)) and SDRAM_ADDR_NEXT(0);
			ddr3ip_be(2) <= SDRAM_ADDR_NEXT(1) and not(SDRAM_ADDR_NEXT(0));
			ddr3ip_be(3) <= SDRAM_ADDR_NEXT(1) and SDRAM_ADDR_NEXT(0);
		when "010" => 
			byteselo <= "01000100";
--			byteseli(0) <= '0';
--			byteseli(1) <= not(SDRAM_ADDR_NEXT(0));
--			byteseli(2) <= '1';
--			byteseli(3) <= not(SDRAM_ADDR_NEXT(0));
--			ddr3ip_be(3) <= not(SDRAM_ADDR_NEXT(0));
--			ddr3ip_be(2) <= not(SDRAM_ADDR_NEXT(0));
--			ddr3ip_be(1) <= SDRAM_ADDR_NEXT(0);
--			ddr3ip_be(0) <= SDRAM_ADDR_NEXT(0);
			
			byteseli(0) <= '0';
			byteseli(1) <= SDRAM_ADDR_NEXT(0);
			byteseli(2) <= '1';
			byteseli(3) <= SDRAM_ADDR_NEXT(0);
			ddr3ip_be(0) <= not(SDRAM_ADDR_NEXT(0));
			ddr3ip_be(1) <= not(SDRAM_ADDR_NEXT(0));
			ddr3ip_be(2) <= SDRAM_ADDR_NEXT(0);
			ddr3ip_be(3) <= SDRAM_ADDR_NEXT(0);			
		when others =>
		end case;
		
		ddr3ip_burstcount <= "0";
		
		ram_state_next <= ram_state_reg;

		case ram_state_reg is
		when ram_state_waitrequest =>

			if SDRAM_REQUEST='1' then
				SDRAM_ADDR_NEXT <= SDRAM_ADDR;
				if ddr3ip_waitrequest='0' then
					ddr3ip_burstcount(0) <= '1';
					if SDRAM_READ_ENABLE='1' then
						ddr3ip_read_req <= '1';
						ram_state_next <= ram_state_waitreadvalid;
					else
						ddr3ip_write_req <= '1';
						SDRAM_REQUEST_COMPLETE <= '1';
					end if;
				else
					if SDRAM_READ_ENABLE='1' then
						ram_state_next <= ram_state_waitread;
					else
						ram_state_next <= ram_state_waitwrite;
					end if;
				end if;
			end if;

		when ram_state_waitwrite =>			
			if ddr3ip_waitrequest='0' then
				ddr3ip_burstcount(0) <= '1';
				ddr3ip_write_req <= '1';
				SDRAM_REQUEST_COMPLETE <= '1';
				ram_state_next <= ram_state_waitrequest;
			end if;

		when ram_state_waitread =>			
			if ddr3ip_waitrequest='0' then
				ddr3ip_burstcount(0) <= '1';
				ddr3ip_read_req <= '1';
				ram_state_next <= ram_state_waitreadvalid;
			end if;
	
		when ram_state_waitreadvalid =>			
			if (ddr3ip_rdata_valid='1') then									
				SDRAM_REQUEST_COMPLETE <= '1';
				ram_state_next <= ram_state_waitrequest;
			end if;			
		when others =>
			ram_state_next <= ram_state_waitrequest;
		end case;
	end process;

zpu: entity work.zpucore
	GENERIC MAP
	(
		platform => 1,
		spi_clock_div => 2, -- 28MHz/2. Max for SD cards is 25MHz...
		memory => 8192,
		usb => 3,
		nMHz_clock_div => 48
	)
	PORT MAP
	(
		-- standard...
		CLK => CLK_ATARI,
		--RESET_N => RESET_N and sdram_rdy,
		RESET_N => RESET_N,

		-- dma bus master (with many waitstates...)
		ZPU_ADDR_FETCH => dma_addr_fetch,
		ZPU_DATA_OUT => dma_write_data,
		ZPU_FETCH => dma_fetch,
		ZPU_32BIT_WRITE_ENABLE => dma_32bit_write_enable,
		ZPU_16BIT_WRITE_ENABLE => dma_16bit_write_enable,
		ZPU_8BIT_WRITE_ENABLE => dma_8bit_write_enable,
		ZPU_READ_ENABLE => dma_read_enable,
		ZPU_MEMORY_READY => dma_memory_ready,
		ZPU_MEMORY_DATA => dma_memory_data, 

		-- rom bus master
		-- data on next cycle after addr
		ZPU_ADDR_ROM => zpu_addr_rom,
		ZPU_ROM_DATA => zpu_rom_data,

		-- spi master
		-- Too painful to bit bang spi from zpu, so we have a hardware master in here
		ZPU_SPI_DI => sd_dat0 and spi_flash_di,
		ZPU_SPI_CLK => spi_clk,
		ZPU_SPI_DO => spi_do,
		ZPU_SPI_SELECT0 => sd_dat3,
		ZPU_SPI_SELECT1 => spi_flash_select,

		-- SIO
		-- Ditto for speaking to Atari, we have a built in Pokey
		ZPU_POKEY_ENABLE => zpu_pokey_enable,
		ZPU_SIO_TXD => zpu_sio_txd,
		ZPU_SIO_RXD => zpu_sio_rxd,
		ZPU_SIO_COMMAND => zpu_sio_command,
		ZPU_SIO_CLK => ASIO_CLOCKOUT,

		-- external control
		-- switches etc. sector DMA blah blah.
		ZPU_IN1 => X"000"&
			'0'&sd_cd&
			(atari_keyboard(28))&ps2_keys(16#5A#)&ps2_keys(16#174#)&ps2_keys(16#16B#)&ps2_keys(16#172#)&ps2_keys(16#175#)& -- (esc)FLRDU
			FKEYS,
		ZPU_IN2 => X"00000000",
		ZPU_IN3 => atari_keyboard(31 downto 0),
		ZPU_IN4 => atari_keyboard(63 downto 32),

		-- ouputs - e.g. Atari system control, halt, throttle, rom select
		ZPU_OUT1 => zpu_out1, --misc
		ZPU_OUT2 => zpu_out2, --joy0
		ZPU_OUT3 => zpu_out3, --joy1
		ZPU_OUT4 => zpu_out4, --keyboard
		ZPU_OUT5 => zpu_out5, --analog stick
		ZPU_OUT6 => zpu_out6,

		-- USB host
		CLK_nMHz => CLK_USB,
		CLK_USB => CLK_USB,
	
		USBWireVPin => USBWireVPin,
		USBWireVMin => USBWireVMin,
		USBWireVPout => USBWireVPout,
		USBWireVMout => USBWireVMout,
		USBWireOE_n => USBWireOE_n
	);

	pause_atari <= zpu_out1(0);
	reset_atari <= zpu_out1(1);
	speed_6502 <= zpu_out1(7 downto 2);
	ram_select <= zpu_out1(10 downto 8);
	atari800mode <= zpu_out1(11);
	emulated_cartridge_select <= zpu_out1(22 downto 17);
	freezer_enable <= zpu_out1(25);
	key_type <= zpu_out1(26);
	turbo_vblank_only <= zpu_out1(31);

	video_mode <= zpu_out6(2 downto 0);
	PAL <= zpu_out6(4);
	scanlines <= zpu_out6(5);
	csync <= zpu_out6(6);

sfl_spi : sfl
	port map(
		asmi_access_granted => '0',
		asmi_access_request => open,
		data_in(0)          => spi_do,
		data_in(1)          => 'Z',
		data_in(2)          => 'Z',
		data_in(3)          => 'Z',
		data_oe(0)          => not(spi_flash_select),
		data_oe(1)          => '0',
		data_oe(2)          => '0',
		data_oe(3)          => '0',
		data_out(0)         => open,
		data_out(1)         => spi_flash_di,
		data_out(2)         => open,
		data_out(3)         => open,
		dclk_in             => spi_clk,
		ncso_in             => spi_flash_select,
		noe_in              => '0' -- ?
	);
	sd_cmd <= spi_do;
	sd_clk <= spi_clk;
	
	zpu_rom1: entity work.zpu_rom
	port map(
	        clock => clk_atari,
	        address => zpu_addr_rom(15 downto 2),
	        q => zpu_rom_data
	);

enable_179_clock_div_zpu_pokey : entity work.enable_divider
	generic map (COUNT=>16) -- cycle_length
	port map(clk=>clk_atari,reset_n=>reset_n,enable_in=>'1',enable_out=>zpu_pokey_enable);

-- PS2 to pokey
keyboard_map1 : entity work.ps2_to_atari800
	GENERIC MAP
	(
		ps2_enable => 1,
		direct_enable => 1
	)
	PORT MAP
	( 
		CLK => clk_atari,
		RESET_N => reset_n,
		PS2_CLK => '1', -- No PS2...
		PS2_DAT => '1', -- No PS2...

		INPUT => zpu_out4,

		KEY_TYPE => key_type,
 		ATARI_KEYBOARD_OUT => atari_keyboard,
		
		KEYBOARD_SCAN => KEYBOARD_SCAN,
		KEYBOARD_RESPONSE => KEYBOARD_RESPONSE,

		CONSOL_START => CONSOL_START,
		CONSOL_SELECT => CONSOL_SELECT,
		CONSOL_OPTION => CONSOL_OPTION,
		
		FKEYS => FKEYS,
		FREEZER_ACTIVATE => freezer_activate,

		PS2_KEYS_NEXT_OUT => ps2_keys_next,
		PS2_KEYS => ps2_keys
	);

-- USB
USB1_DN <= USBWireVMout(2) when USBWireOE_n(2)='0' else 'Z';
USB1_DP <= USBWireVPout(2) when USBWireOE_n(2)='0' else 'Z';
USBWireVMin(2) <= USB1_DN;
USBWireVPin(2) <= USB1_DP;

USB2_DN <= USBWireVMout(1) when USBWireOE_n(1)='0' else 'Z';
USB2_DP <= USBWireVPout(1) when USBWireOE_n(1)='0' else 'Z';
USBWireVMin(1) <= USB2_DN;
USBWireVPin(1) <= USB2_DP;

USB3_DN <= USBWireVMout(0) when USBWireOE_n(0)='0' else 'Z';
USB3_DP <= USBWireVPout(0) when USBWireOE_n(0)='0' else 'Z';
USBWireVMin(0) <= USB3_DN;
USBWireVPin(0) <= USB3_DP;


pllusbinstance : pll_usb
PORT MAP(refclk => CLK0, 
		 outclk_0 => CLK_USB,
		 outclk_1 => open,
		 locked => open);
		 
pllaudinstance : pll_aud
PORT MAP(refclk => CLK0, 
		 outclk_0 => CLK_AUD,
		 locked => open);		 

END vhdl;

