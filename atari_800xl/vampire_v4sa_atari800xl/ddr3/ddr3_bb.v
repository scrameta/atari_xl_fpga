
module ddr3 (
	clkatari_clk,
	ddrext_mem_a,
	ddrext_mem_ba,
	ddrext_mem_ck,
	ddrext_mem_ck_n,
	ddrext_mem_cke,
	ddrext_mem_cs_n,
	ddrext_mem_dm,
	ddrext_mem_ras_n,
	ddrext_mem_cas_n,
	ddrext_mem_we_n,
	ddrext_mem_reset_n,
	ddrext_mem_dq,
	ddrext_mem_dqs,
	ddrext_mem_dqs_n,
	ddrext_mem_odt,
	ddrint_waitrequest,
	ddrint_readdata,
	ddrint_readdatavalid,
	ddrint_burstcount,
	ddrint_writedata,
	ddrint_address,
	ddrint_write,
	ddrint_read,
	ddrint_byteenable,
	ddrint_debugaccess,
	ddroct_rzqin,
	ddrpll_pll_mem_clk,
	ddrpll_pll_write_clk,
	ddrpll_pll_locked,
	ddrpll_pll_write_clk_pre_phy_clk,
	ddrpll_pll_addr_cmd_clk,
	ddrpll_pll_avl_clk,
	ddrpll_pll_config_clk,
	ddrpll_pll_mem_phy_clk,
	ddrpll_afi_phy_clk,
	ddrpll_pll_avl_phy_clk,
	ddrrefclk_clk,
	ddrrefresh_local_refresh_req,
	ddrrefresh_local_refresh_chip,
	ddrrefresh_local_refresh_ack,
	ddrstatus_local_init_done,
	ddrstatus_local_cal_success,
	ddrstatus_local_cal_fail,
	reset_n_reset_n,
	softreset_n_reset_n,
	refresh_clk_clk);	

	input		clkatari_clk;
	output	[14:0]	ddrext_mem_a;
	output	[2:0]	ddrext_mem_ba;
	output	[0:0]	ddrext_mem_ck;
	output	[0:0]	ddrext_mem_ck_n;
	output	[0:0]	ddrext_mem_cke;
	output	[0:0]	ddrext_mem_cs_n;
	output	[1:0]	ddrext_mem_dm;
	output	[0:0]	ddrext_mem_ras_n;
	output	[0:0]	ddrext_mem_cas_n;
	output	[0:0]	ddrext_mem_we_n;
	output		ddrext_mem_reset_n;
	inout	[15:0]	ddrext_mem_dq;
	inout	[1:0]	ddrext_mem_dqs;
	inout	[1:0]	ddrext_mem_dqs_n;
	output	[0:0]	ddrext_mem_odt;
	output		ddrint_waitrequest;
	output	[31:0]	ddrint_readdata;
	output		ddrint_readdatavalid;
	input	[0:0]	ddrint_burstcount;
	input	[31:0]	ddrint_writedata;
	input	[26:0]	ddrint_address;
	input		ddrint_write;
	input		ddrint_read;
	input	[3:0]	ddrint_byteenable;
	input		ddrint_debugaccess;
	input		ddroct_rzqin;
	output		ddrpll_pll_mem_clk;
	output		ddrpll_pll_write_clk;
	output		ddrpll_pll_locked;
	output		ddrpll_pll_write_clk_pre_phy_clk;
	output		ddrpll_pll_addr_cmd_clk;
	output		ddrpll_pll_avl_clk;
	output		ddrpll_pll_config_clk;
	output		ddrpll_pll_mem_phy_clk;
	output		ddrpll_afi_phy_clk;
	output		ddrpll_pll_avl_phy_clk;
	input		ddrrefclk_clk;
	input		ddrrefresh_local_refresh_req;
	input	[0:0]	ddrrefresh_local_refresh_chip;
	output		ddrrefresh_local_refresh_ack;
	output		ddrstatus_local_init_done;
	output		ddrstatus_local_cal_success;
	output		ddrstatus_local_cal_fail;
	input		reset_n_reset_n;
	input		softreset_n_reset_n;
	output		refresh_clk_clk;
endmodule
