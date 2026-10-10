#============================================================================
# Tank - SDC Timing Constraints
#============================================================================

derive_pll_clocks
derive_clock_uncertainty

# The core runs at 14.318181 MHz (clk_sys) with its video output on
# 85.909 MHz (CLK_VIDEO), both from one PLL.
#
# The framework's sys_top.sdc puts each core PLL in its own clock group by
# matching the MegaWizard altera_pll name.  This core's PLL is a direct
# altpll instance (rtl/pll.v), named differently, so it is grouped here.
# Without this, every crossing between the core and the framework (which
# synchronises them itself) would be timed as synchronous.  generic_pll*
# covers both outputs: they share one VCO, so the clk_sys -> CLK_VIDEO
# transfer in Arcade-Tank.sv is still timed, as the synchronous transfer
# it is.
set_clock_groups -exclusive \
   -group [get_clocks {emu|pll|pll_inst|auto_generated|generic_pll*~PLL_OUTPUT_COUNTER|divclk}] \
   -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks {spi_sck}] \
   -group [get_clocks {hdmi_sck}] \
   -group [get_clocks {*|h2f_user0_clk}] \
   -group [get_clocks {FPGA_CLK1_50}] \
   -group [get_clocks {FPGA_CLK2_50}] \
   -group [get_clocks {FPGA_CLK3_50}]
