//============================================================================
// Blast (shell explosion) object generator
//============================================================================
//
// BLAST1 / BLAST2 as drawn on the Board I Rev H schematic.  Both players'
// explosions use the same circuit:
//
//   BLASTn = window AND EXPLn AND K3.6 AND K1.4                  (IC_L2/L4 NAND4)
//
//   Pattern gate (geometric S-tap texture + ~5 Hz FLASH shimmer):
//     K2.3  = (S4V XOR S8V) XOR (S4H XOR S8H)                    (IC_K2 7486 g1)
//     K3.6  = FLASHQ XOR K2.3                                    (IC_K3 7486)
//     FLASHQ = NOT(FLASH)                                        (IC_J3 7404)
//
//   Inner mask (per-pixel 2px texture):
//     K2.11 = S2V XOR S2H                                        (IC_K2 7486)
//     K1.1  = NOR(S8V XOR S4V, S8H XOR S4H)                      (IC_K1 7402)
//     K1.4  = NOR(K2.11, K1.1)                                   (IC_K1 7402)
//
//   The pattern comes only from the shell counter's taps and FLASH: no
//   tank shape, no BLO_UP.
//
// MAME's netlist differs for BLAST1: it wires K3.5 to K3.3 (the tank-shape
// XOR) instead of K2.3, so its player 1 explosion carries the tank shape.
// BLAST2, on the separate K4, matches the schematic.  The core follows the
// schematic for both.
//
// The S2 / S4 / S8 taps are bits of the shell's position counters, and one
// window (IC_L3.4; IC_K5.13 / IC_L4 for player 2) frames both the shell and
// its explosion.  The shell is columns 4-7, rows 8-11 of that window, so
// tank_video.sv loads this module at (shell x - 4, shell y - 8) and the
// counter phases here equal the board's.
//============================================================================

module blast_object #(
    parameter [9:0] H_LAST      = 10'd903,  // hardware scanline = 904 clocks
    parameter [9:0] V_TICK_A    = 10'd898,  // object V counters tick twice at
    parameter [9:0] V_TICK_B    = 10'd902,  //   LINE START (see v_count_now)
    parameter [9:0] BLAST_SIZE  = 10'd16    // L3.4 window: 16 pixels x 16 half-lines
) (
    input  wire        clk_pix,
    input  wire        reset,

    input  wire [9:0]  hcount,
    input  wire [9:0]  hw_vcnt,
    input  wire        v_load_pulse,  // once per field, at the V wrap

    input  wire [9:0]  x,             // window origin (shell position - (4, 8))
    input  wire [9:0]  y,
    input  wire        active,        // EXPL1 / EXPL2: explosion running
    input  wire        flash,         // FLASH (~5 Hz, IC_A12 7492 / 12)

    output wire        video
);

    //-------------------------------------------------------------------------
    // Horizontal counter, as in shell_object; bits 1/2/3 are S2H/S4H/S8H.
    //-------------------------------------------------------------------------
    wire [9:0] h_load = (~x) + 10'd1;
    wire       h_load_now = (hcount == H_LAST);

    wire [3:0] h_lo_q;
    wire [3:0] h_mid_q;
    wire [3:0] h_hi_q;
    wire       h_lo_rc;
    wire       h_mid_rc;

    ttl_9316 u_h_lo (
        .clk    (clk_pix),
        .clr_n  (~reset),
        .load_n (~h_load_now),
        .enp    (1'b1),
        .ent    (1'b1),
        .d      (h_load[3:0]),
        .q      (h_lo_q),
        .rc     (h_lo_rc)
    );

    ttl_9316 u_h_mid (
        .clk    (clk_pix),
        .clr_n  (~reset),
        .load_n (~h_load_now),
        .enp    (1'b1),
        .ent    (h_lo_rc),
        .d      (h_load[7:4]),
        .q      (h_mid_q),
        .rc     (h_mid_rc)
    );

    ttl_9316 u_h_hi (
        .clk    (clk_pix),
        .clr_n  (~reset),
        .load_n (~h_load_now),
        .enp    (1'b1),
        .ent    (h_mid_rc),
        .d      ({2'b00, h_load[9:8]}),
        .q      (h_hi_q),
        .rc     ()
    );

    wire [9:0] h_phase = {h_hi_q[1:0], h_mid_q, h_lo_q};
    wire       h_blast_window = (h_phase < BLAST_SIZE);

    //-------------------------------------------------------------------------
    // Vertical counter, ticking twice a line; bits 1/2/3 are S2V/S4V/S8V.
    //-------------------------------------------------------------------------
    wire [9:0] v_load = (hcount == 10'd452) ? (~y) : ((~y) + 10'd1);
    wire       v_load_now  = v_load_pulse;
    // V counter reload and ticks: as in tank_object.sv.
    wire       v_count_now = (hcount == V_TICK_A) || (hcount == V_TICK_B);

    wire [3:0] v_lo_q;
    wire [3:0] v_mid_q;
    wire [3:0] v_hi_q;
    wire       v_lo_rc;
    wire       v_mid_rc;

    ttl_9316 u_v_lo (
        .clk    (clk_pix),
        .clr_n  (~reset),
        .load_n (~v_load_now),
        .enp    (v_count_now),
        .ent    (1'b1),
        .d      (v_load[3:0]),
        .q      (v_lo_q),
        .rc     (v_lo_rc)
    );

    ttl_9316 u_v_mid (
        .clk    (clk_pix),
        .clr_n  (~reset),
        .load_n (~v_load_now),
        .enp    (v_count_now),
        .ent    (v_lo_rc),
        .d      (v_load[7:4]),
        .q      (v_mid_q),
        .rc     (v_mid_rc)
    );

    ttl_9316 u_v_hi (
        .clk    (clk_pix),
        .clr_n  (~reset),
        .load_n (~v_load_now),
        .enp    (v_count_now),
        .ent    (v_mid_rc),
        .d      ({2'b00, v_load[9:8]}),
        .q      (v_hi_q),
        .rc     ()
    );

    wire [9:0] v_phase = {v_hi_q[1:0], v_mid_q, v_lo_q};
    wire       v_blast_window = (v_phase < BLAST_SIZE);

    wire blast_window = h_blast_window && v_blast_window;   // L3.4 window model

    //-------------------------------------------------------------------------
    // K1.4 inner mask - per-pixel 2px checker from the shell S-taps.
    //-------------------------------------------------------------------------
    wire s2h = h_phase[1];
    wire s4h = h_phase[2];
    wire s8h = h_phase[3];
    wire s2v = v_phase[1];
    wire s4v = v_phase[2];
    wire s8v = v_phase[3];

    wire k2_11 = s2h ^ s2v;                              // IC_K2.11 = XOR(S2V, S2H)
    wire k1_1  = ~((s8v ^ s4v) | (s8h ^ s4h));           // IC_K1.1  = NOR(S8V^S4V, S8H^S4H)
    wire k1_4  = ~(k2_11 | k1_1);                        // IC_K1.4  = NOR(K2.11, K1.1)

    //-------------------------------------------------------------------------
    // K3.6 pattern gate: the S-tap pattern XOR FLASH (see the header).
    //-------------------------------------------------------------------------
    wire flashq = ~flash;                                // IC_J3.4 = NOT(FLASH)
    wire k2_3   = (s4v ^ s8v) ^ (s4h ^ s8h);             // IC_K2.3 = XOR(S4V^S8V, S4H^S8H)
    wire k3_6   = flashq ^ k2_3;                         // IC_K3.6 = XOR(FLASHQ, K2.3)

    // BLASTn = window AND EXPLn AND K3.6 AND K1.4  (IC_L2/L4 4-input NAND -> N4 inv)
    assign video = active && blast_window && k3_6 && k1_4;

endmodule
