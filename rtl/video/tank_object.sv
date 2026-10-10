//============================================================================
// Tank object generator
//============================================================================
//
// One tank, drawn as on Board II: 9316 counters loaded from the tank's
// position count through the raster, and the 16 x 16 window is where they
// pass 0..15.  The V count also gives the shape row; each row's 16 pixels
// come from two ROM bytes (C2 fetch) into a shift register.
//
// x / y come from tank_motion.  The core decodes the window straight from
// the counters, without the board's one-clock re-timing through IC_F3
// (a 7474).
//============================================================================

module tank_object #(
    parameter [9:0] H_LAST        = 10'd903,  // hardware scanline = 904 clocks
    parameter [9:0] V_TICK_A      = 10'd898,  // object V counters tick twice at
    parameter [9:0] V_TICK_B      = 10'd902,  //   LINE START (see v_count_now)
    parameter [9:0] FETCH_A_START = 10'd460,
    parameter [9:0] FETCH_A_END   = 10'd463,
    parameter [9:0] FETCH_B_START = 10'd464,
    parameter [9:0] FETCH_B_END   = 10'd467,
    parameter [9:0] LATCH_A_AT    = 10'd462,
    parameter [9:0] LATCH_B_AT    = 10'd466
) (
    input  wire        clk_pix,
    input  wire        reset,

    input  wire [9:0]  hcount,
    input  wire [9:0]  hw_vcnt,
    input  wire        v_load_pulse,  // once per field, at the V wrap

    input  wire [4:0]  rot,
    input  wire [9:0]  x,
    input  wire [9:0]  y,

    input  wire [7:0]  rom_data,
    output wire [10:0] rom_addr,
    output wire        video,
    // WINDO: high inside the 16 x 16 box (tank_core flashes the tank
    // inside it while it explodes).
    output wire        window,
    // TVR (IC_C1.11 TVR1Q, active high here): the last count of the V
    // window.  Feeds the shell-arm clear SRS = NOR(TVR1Q, FPE1) in
    // tank_shells.
    output wire        tvr
);

    //-------------------------------------------------------------------------
    // Horizontal phase counter.
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
    wire       h_window = (h_phase < 10'd16);

    //-------------------------------------------------------------------------
    // Vertical phase counter.
    //-------------------------------------------------------------------------
    // Reload once per field.  The board's counter runs freely with a period
    // of 521 ticks (one field) but ticks only at line starts: a field that
    // starts at hcount 0 holds 261 line starts (522 ticks), one that starts
    // at hcount 452 only 520.  Loading -y in the first and -y-1 in the
    // second reproduces that, and puts each y at its own half-line across
    // the two fields.
    wire [9:0] v_load = (hcount == 10'd452) ? (~y) : ((~y) + 10'd1);
    wire       v_load_now = v_load_pulse;
    // The board clocks the object V counters (tank IC_A2/B2/C2, shell
    // IC_F1/H1/J1) with H_COUNT1 = NOT(NAND(H_SYNC, NOR(H8,H16), H2)): two
    // pulses at hc 2 and hc 6 of every line, so an object's rows change only
    // between lines and an object is never split across hcount 452.  The
    // core ticks at the end of the previous line instead (hcount 898 / 902):
    // nothing is drawn there, and the new row is ready for the shape fetch
    // at hcount 0..15.  The reload (hcount 0 or 452) never meets a tick.
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
    wire       v_window = (v_phase < 10'd16);
    wire [2:0] row = v_phase[3:1];

    //-------------------------------------------------------------------------
    // C2 shape ROM address and shift register.
    //-------------------------------------------------------------------------
    wire fetch_a = (hcount >= FETCH_A_START) && (hcount <= FETCH_A_END);
    wire fetch_b = (hcount >= FETCH_B_START) && (hcount <= FETCH_B_END);

    assign rom_addr = fetch_a ? {2'b11, rot[3:0], 1'b0, rot[4], row}
                    : fetch_b ? {2'b11, rot[3:0], 1'b1, rot[4], row}
                    :           11'd0;

    reg [15:0] shift_reg;

    always @(posedge clk_pix) begin
        if (reset) begin
            shift_reg <= 16'd0;
        end else begin
            if (hcount == LATCH_A_AT) begin
                shift_reg[15:8] <= rom_data;
            end
            if (hcount == LATCH_B_AT) begin
                shift_reg[7:0] <= rom_data;
            end
            if ((hcount != LATCH_A_AT) && (hcount != LATCH_B_AT) && h_window && v_window) begin
                // Shift in 1s: the serial input of the A3 -> B3 74165 pair
                // (IC_A3.10) is tied to VCC.  They never reach [15] inside
                // the window.
                shift_reg <= {shift_reg[14:0], 1'b1};
            end
        end
    end

    assign video  = (h_window && v_window) ? shift_reg[15] : 1'b0;
    assign window = h_window && v_window;
    assign tvr    = (v_phase == 10'd15);

endmodule
