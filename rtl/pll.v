//============================================================================
// Tank - PLL: Generates 14.318181 MHz from 50 MHz input
//============================================================================
//
// Original Tank crystal: 14.318181 MHz (4x NTSC color subcarrier ~3.579545 MHz)
//
// PLL Parameters (Cyclone V Integer-N PLL):
//   Input:  50.0 MHz
//   Output: 14.318181 MHz  (exact value 315/22 MHz, 4x NTSC subcarrier)
//   Output:  85.909090 MHz (6x the above) -- CLK_VIDEO for CRT Adjust
//
//   Requested ratios: clk0 = 50 * 63 / 220  = 14.318181... MHz
//                     clk1 = 50 * 189 / 110 = 85.909090... MHz
//   Both from one VCO, so the two outputs are phase-locked (rising edges
//   coincide every 6 clk1 cycles) and Quartus times the core->video
//   crossing as synchronous.  Quartus' fitter resolves the pair to an
//   integer PLL with M=189, N=10: VCO = 50 * 189 / 10 = 945 MHz (in the
//   ~600-1600 MHz range), C0 = 66 -> 14.318181 MHz, C1 = 11 -> 85.909 MHz
//   (Tank.fit.rpt, 2026-10-08).
//   (Before CRT Adjust the single output used M=126, N=5, C0=88, VCO 1260.
//   An 8x clk1 = 114.545 MHz fits that VCO, but the framework's yc_out
//   composite encoder on CLK_VIDEO then fails timing by ~1.1 ns.)
//
//   This wrapper uses ALTPLL direct instantiation for synthesis
//   without requiring the Quartus MegaWizard generated files.
//   To regenerate in Quartus MegaWizard:
//     - Launch IP Catalog → PLL → ALTPLL
//     - Device: Cyclone V, Speed Grade 6
//     - Reference: 50.000 MHz
//     - Output c0: 14.318181 MHz, duty 50%
//     - Use integer-N PLL in normal mode
//============================================================================

`timescale 1 ps / 1 ps
module pll (
    input  wire refclk,    // 50 MHz reference clock
    input  wire rst,       // asynchronous reset
    output wire outclk_0,  // 14.318 MHz output clock (core)
    output wire outclk_1,  // 85.909 MHz output clock (video, 6x)
    output wire locked     // PLL locked indicator
);

    // Using ALTPLL megafunction for Cyclone V.
    // clk0_multiply_by / clk0_divide_by = 63 / 220 requests
    // 50 * 63 / 220 = 14.318181 MHz, the exact original crystal frequency.
    // clk1 = 50 * 189 / 110 = 85.909 MHz = 6 x clk0 (VCO 945 MHz, see top).

    wire [9:0] clk_w;

    altpll #(
        .bandwidth_type          ("AUTO"),
        .clk0_divide_by          (220),
        .clk0_duty_cycle         (50),
        .clk0_multiply_by        (63),
        .clk0_phase_shift        ("0"),
        .clk1_divide_by          (110),
        .clk1_duty_cycle         (50),
        .clk1_multiply_by        (189),
        .clk1_phase_shift        ("0"),
        .compensate_clock        ("CLK0"),
        .inclk0_input_frequency  (20000),    // 50 MHz = 20000 ps period
        .intended_device_family  ("Cyclone V"),
        .lpm_hint                ("CBX_MODULE_PREFIX=pll"),
        .lpm_type                ("altpll"),
        .operation_mode          ("NORMAL"),
        .pll_type                ("AUTO"),
        .port_activeclock        ("PORT_UNUSED"),
        .port_areset             ("PORT_UNUSED"),
        .port_clkbad0            ("PORT_UNUSED"),
        .port_clkbad1            ("PORT_UNUSED"),
        .port_clkloss            ("PORT_UNUSED"),
        .port_clkswitch          ("PORT_UNUSED"),
        .port_configupdate       ("PORT_UNUSED"),
        .port_fbin               ("PORT_UNUSED"),
        .port_inclk0             ("PORT_USED"),
        .port_inclk1             ("PORT_UNUSED"),
        .port_locked             ("PORT_USED"),
        .port_pfdena             ("PORT_UNUSED"),
        .port_phasecounterselect ("PORT_UNUSED"),
        .port_phasedone          ("PORT_UNUSED"),
        .port_phasestep          ("PORT_UNUSED"),
        .port_phaseupdown        ("PORT_UNUSED"),
        .port_pllena             ("PORT_UNUSED"),
        .port_scanaclr           ("PORT_UNUSED"),
        .port_scanclk            ("PORT_UNUSED"),
        .port_scanclkena         ("PORT_UNUSED"),
        .port_scandata           ("PORT_UNUSED"),
        .port_scandataout        ("PORT_UNUSED"),
        .port_scandone           ("PORT_UNUSED"),
        .port_scanread           ("PORT_UNUSED"),
        .port_scanwrite          ("PORT_UNUSED"),
        .port_clk0               ("PORT_USED"),
        .port_clk1               ("PORT_USED"),
        .port_clk2               ("PORT_UNUSED"),
        .port_clk3               ("PORT_UNUSED"),
        .port_clk4               ("PORT_UNUSED"),
        .port_clk5               ("PORT_UNUSED"),
        .port_clk6               ("PORT_UNUSED"),
        .port_clk7               ("PORT_UNUSED"),
        .port_clk8               ("PORT_UNUSED"),
        .port_clk9               ("PORT_UNUSED"),
        .self_reset_on_loss_lock ("OFF"),
        .width_clock             (10)
    ) pll_inst (
        .inclk  ({1'b0, refclk}),
        .clk    (clk_w),
        .locked (locked)
    );

    assign outclk_0 = clk_w[0];
    assign outclk_1 = clk_w[1];

endmodule
