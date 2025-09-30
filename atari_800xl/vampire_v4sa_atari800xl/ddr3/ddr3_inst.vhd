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
			ddrrefresh_local_refresh_req     : in    std_logic                     := 'X';             -- local_refresh_req
			ddrrefresh_local_refresh_chip    : in    std_logic_vector(0 downto 0)  := (others => 'X'); -- local_refresh_chip
			ddrrefresh_local_refresh_ack     : out   std_logic;                                        -- local_refresh_ack
			ddrstatus_local_init_done        : out   std_logic;                                        -- local_init_done
			ddrstatus_local_cal_success      : out   std_logic;                                        -- local_cal_success
			ddrstatus_local_cal_fail         : out   std_logic;                                        -- local_cal_fail
			reset_n_reset_n                  : in    std_logic                     := 'X';             -- reset_n
			softreset_n_reset_n              : in    std_logic                     := 'X';             -- reset_n
			refresh_clk_clk                  : out   std_logic                                         -- clk
		);
	end component ddr3;

	u0 : component ddr3
		port map (
			clkatari_clk                     => CONNECTED_TO_clkatari_clk,                     --    clkatari.clk
			ddrext_mem_a                     => CONNECTED_TO_ddrext_mem_a,                     --      ddrext.mem_a
			ddrext_mem_ba                    => CONNECTED_TO_ddrext_mem_ba,                    --            .mem_ba
			ddrext_mem_ck                    => CONNECTED_TO_ddrext_mem_ck,                    --            .mem_ck
			ddrext_mem_ck_n                  => CONNECTED_TO_ddrext_mem_ck_n,                  --            .mem_ck_n
			ddrext_mem_cke                   => CONNECTED_TO_ddrext_mem_cke,                   --            .mem_cke
			ddrext_mem_cs_n                  => CONNECTED_TO_ddrext_mem_cs_n,                  --            .mem_cs_n
			ddrext_mem_dm                    => CONNECTED_TO_ddrext_mem_dm,                    --            .mem_dm
			ddrext_mem_ras_n                 => CONNECTED_TO_ddrext_mem_ras_n,                 --            .mem_ras_n
			ddrext_mem_cas_n                 => CONNECTED_TO_ddrext_mem_cas_n,                 --            .mem_cas_n
			ddrext_mem_we_n                  => CONNECTED_TO_ddrext_mem_we_n,                  --            .mem_we_n
			ddrext_mem_reset_n               => CONNECTED_TO_ddrext_mem_reset_n,               --            .mem_reset_n
			ddrext_mem_dq                    => CONNECTED_TO_ddrext_mem_dq,                    --            .mem_dq
			ddrext_mem_dqs                   => CONNECTED_TO_ddrext_mem_dqs,                   --            .mem_dqs
			ddrext_mem_dqs_n                 => CONNECTED_TO_ddrext_mem_dqs_n,                 --            .mem_dqs_n
			ddrext_mem_odt                   => CONNECTED_TO_ddrext_mem_odt,                   --            .mem_odt
			ddrint_waitrequest               => CONNECTED_TO_ddrint_waitrequest,               --      ddrint.waitrequest
			ddrint_readdata                  => CONNECTED_TO_ddrint_readdata,                  --            .readdata
			ddrint_readdatavalid             => CONNECTED_TO_ddrint_readdatavalid,             --            .readdatavalid
			ddrint_burstcount                => CONNECTED_TO_ddrint_burstcount,                --            .burstcount
			ddrint_writedata                 => CONNECTED_TO_ddrint_writedata,                 --            .writedata
			ddrint_address                   => CONNECTED_TO_ddrint_address,                   --            .address
			ddrint_write                     => CONNECTED_TO_ddrint_write,                     --            .write
			ddrint_read                      => CONNECTED_TO_ddrint_read,                      --            .read
			ddrint_byteenable                => CONNECTED_TO_ddrint_byteenable,                --            .byteenable
			ddrint_debugaccess               => CONNECTED_TO_ddrint_debugaccess,               --            .debugaccess
			ddroct_rzqin                     => CONNECTED_TO_ddroct_rzqin,                     --      ddroct.rzqin
			ddrpll_pll_mem_clk               => CONNECTED_TO_ddrpll_pll_mem_clk,               --      ddrpll.pll_mem_clk
			ddrpll_pll_write_clk             => CONNECTED_TO_ddrpll_pll_write_clk,             --            .pll_write_clk
			ddrpll_pll_locked                => CONNECTED_TO_ddrpll_pll_locked,                --            .pll_locked
			ddrpll_pll_write_clk_pre_phy_clk => CONNECTED_TO_ddrpll_pll_write_clk_pre_phy_clk, --            .pll_write_clk_pre_phy_clk
			ddrpll_pll_addr_cmd_clk          => CONNECTED_TO_ddrpll_pll_addr_cmd_clk,          --            .pll_addr_cmd_clk
			ddrpll_pll_avl_clk               => CONNECTED_TO_ddrpll_pll_avl_clk,               --            .pll_avl_clk
			ddrpll_pll_config_clk            => CONNECTED_TO_ddrpll_pll_config_clk,            --            .pll_config_clk
			ddrpll_pll_mem_phy_clk           => CONNECTED_TO_ddrpll_pll_mem_phy_clk,           --            .pll_mem_phy_clk
			ddrpll_afi_phy_clk               => CONNECTED_TO_ddrpll_afi_phy_clk,               --            .afi_phy_clk
			ddrpll_pll_avl_phy_clk           => CONNECTED_TO_ddrpll_pll_avl_phy_clk,           --            .pll_avl_phy_clk
			ddrrefclk_clk                    => CONNECTED_TO_ddrrefclk_clk,                    --   ddrrefclk.clk
			ddrrefresh_local_refresh_req     => CONNECTED_TO_ddrrefresh_local_refresh_req,     --  ddrrefresh.local_refresh_req
			ddrrefresh_local_refresh_chip    => CONNECTED_TO_ddrrefresh_local_refresh_chip,    --            .local_refresh_chip
			ddrrefresh_local_refresh_ack     => CONNECTED_TO_ddrrefresh_local_refresh_ack,     --            .local_refresh_ack
			ddrstatus_local_init_done        => CONNECTED_TO_ddrstatus_local_init_done,        --   ddrstatus.local_init_done
			ddrstatus_local_cal_success      => CONNECTED_TO_ddrstatus_local_cal_success,      --            .local_cal_success
			ddrstatus_local_cal_fail         => CONNECTED_TO_ddrstatus_local_cal_fail,         --            .local_cal_fail
			reset_n_reset_n                  => CONNECTED_TO_reset_n_reset_n,                  --     reset_n.reset_n
			softreset_n_reset_n              => CONNECTED_TO_softreset_n_reset_n,              -- softreset_n.reset_n
			refresh_clk_clk                  => CONNECTED_TO_refresh_clk_clk                   -- refresh_clk.clk
		);

