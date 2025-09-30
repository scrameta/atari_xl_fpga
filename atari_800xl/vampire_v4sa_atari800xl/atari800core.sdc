create_clock -period 50.000MHz [get_ports CLK0]
create_clock -period 50.000MHz [get_ports CLK1]
derive_pll_clocks
derive_clock_uncertainty

set_clock_groups -asynchronous \
  -group { CLK0 } \
  -group { CLK1 } \
  -group { \
        pll_ntsc_inst|pll_ntsc_inst|altera_pll_i|general[0].gpll~FRACTIONAL_PLL|vcoph[0] \
        pll_ntsc_inst|pll_ntsc_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
  } \
  -group { \
        pll_pal_inst|pll_pal_inst|altera_pll_i|general[0].gpll~FRACTIONAL_PLL|vcoph[0] \
        pll_pal_inst|pll_pal_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
  } \
  -group { \
	pll2_inst|pll2_inst|altera_pll_i|general[0].gpll~FRACTIONAL_PLL|vcoph[0] \
	pll2_inst|pll2_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
	pll2_inst|pll2_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk
  } \
  -group { \
	pllusbinstance|pll_usb_inst|altera_pll_i|general[0].gpll~FRACTIONAL_PLL|vcoph[0]
	pllusbinstance|pll_usb_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
  } \
  -group { \
	pllaudinstance|pll_aud_inst|altera_pll_i|general[0].gpll~FRACTIONAL_PLL|vcoph[0]
	pllaudinstance|pll_aud_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
  } \
  -group { \
	ddr3_inst|mem_if_ddr3_emif_0|ddr3_mem_if_ddr3_emif_0_p0_sampling_clock
	ddr3_inst|mem_if_ddr3_emif_0|pll0|pll1~FRACTIONAL_PLL|vcoph[0]
	ddr3_inst|mem_if_ddr3_emif_0|pll0|pll1~PLL_OUTPUT_COUNTER|divclk
	ddr3_inst|mem_if_ddr3_emif_0|pll0|pll2_phy~PLL_OUTPUT_COUNTER|divclk
	ddr3_inst|mem_if_ddr3_emif_0|pll0|pll3~PLL_OUTPUT_COUNTER|divclk
	ddr3_inst|mem_if_ddr3_emif_0|pll0|pll5~PLL_OUTPUT_COUNTER|divclk
	ddr3_inst|mem_if_ddr3_emif_0|pll0|pll6_phy~PLL_OUTPUT_COUNTER|divclk
	ddr3_inst|mem_if_ddr3_emif_0|pll0|pll6~PLL_OUTPUT_COUNTER|divclk
	ddr3_inst|mem_if_ddr3_emif_0|pll0|pll7~PLL_OUTPUT_COUNTER|divclk
  }
