//============================================================================
// Shell object generator
//============================================================================
//
// One shell: counters as in tank_object.sv, drawing a solid 4 x 4 block
// (no ROM).  On the board the shell's X counter is IC_H2/J2 and its Y
// counter IC_F1/H1/J1, and
//   SHELL = window & FIRE & NOR(S4V, S8H) & AND(S4H, S8V)
// (IC_L3 7402, IC_M3 7408 -> IC_L2 7420 -> IC_N4) carves a 4-pixel by
// 4-half-line block out of a 16 x 16 window it shares with the explosion:
// columns 4-7, rows 8-11.  This module draws that block at (x, y);
// tank_video.sv puts the explosion window at (x - 4, y - 8) to match
// (checked on the netlist at 128 positions per player).
//============================================================================

module shell_object #(
    parameter [9:0] H_LAST      = 10'd903,  // hardware scanline = 904 clocks
    parameter [9:0] V_TICK_A    = 10'd898,  // object V counters tick twice at
    parameter [9:0] V_TICK_B    = 10'd902,  //   LINE START (see v_count_now)
    parameter [3:0] SHELL_SIZE  = 4'd4    // 4 pixels in each axis
) (
    input  wire        clk_pix,
    input  wire        reset,

    input  wire [9:0]  hcount,
    input  wire [9:0]  hw_vcnt,
    input  wire        v_load_pulse,  // once per field, at the V wrap

    input  wire [9:0]  x,
    input  wire [9:0]  y,
    input  wire        active,

    output wire        video
);

    //-------------------------------------------------------------------------
    // Horizontal counter: as in tank_object, with a 4-clock window.
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
    wire       h_window = (h_phase < {6'd0, SHELL_SIZE});

    //-------------------------------------------------------------------------
    // Vertical counter: ticks twice a line, so it counts half-lines like y.
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
    wire       v_window = (v_phase < {6'd0, SHELL_SIZE});

    //-------------------------------------------------------------------------
    // The solid 4 x 4 block (see the header); drawn only in flight.
    //-------------------------------------------------------------------------
    assign video = active && h_window && v_window;

endmodule
