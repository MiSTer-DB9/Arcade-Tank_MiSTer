//============================================================================
// Tank (Kee Games / Atari, 1974) - video sync and raster counters
//============================================================================
//
// The board's H chain counts 904 clocks a line (9316s; decode 450 + H2
// through IC_K12 gives a 452-clock half-line).  Its V counter counts
// HALF-LINES and resets after 521 of them (V512 & V8 decode, 7493 clear).
// 521 is odd, so a field ends alternately at hcount 0 and at hcount 452:
// a true interlaced raster, 260.5 lines a field, fields half a line apart.
// The tanks' Y motion agrees: its stop code gives a period of 528 - 7 = 521
// half-lines, one field, so a still tank stays still.
//
// Field rate: 14318181 / (904 x 260.5) = 60.80 Hz; frame 30.40 Hz.
//
// Active picture: hcount 128..901, half-lines 8..511.
// HSYNC: hcount 32..63 (2.23 us).  The monitor's sync is COMP_SYNC =
//        NOR(IC_A14.6, V_SYNC), A14.6 = H_INFO & !H_SYNC & !64H, i.e. the
//        32 clocks after the internal H_SYNC net (hcount 0..31, which only
//        feeds H_INFO, H_COUNT and the minefield).
// VSYNC: half-lines 0..7 (4 lines), the IC_B11 latch set at V_RESET and
//        cleared at V8.
//
// The counters have no reset input: on the board they are cleared only by
// their own decodes, and a free-running sync keeps the scaler locked
// through a MiSTer reset.  They power up at hcount 0, half-line 0, field 0;
// tank_core releases the game reset at that same raster point.
//============================================================================

module video_sync (
    input  wire       clk_pix,     // 14.318181 MHz pixel clock (no reset)

    output reg        hsync,       // horizontal sync (active high)
    output reg        vsync = 1'b0, // vertical sync (active high, whole lines)
    output reg        hblank,      // horizontal blanking
    output reg        vblank = 1'b1, // vertical blanking (whole lines)
    output reg        de,          // data enable
    output reg [9:0]  hcount = 10'd0, // clock within the line (0..903)
    output wire [9:0]  vcount,     // line = hw_vcnt >> 1 (0..260)
    output reg [9:0]  hw_vcnt = 10'd0, // V counter in half-lines (0..520)
    output reg        field = 1'b0, // VGA_F1: 0 = the field whose V wrap is at
                                   //   hcount 0, 1 = at hcount 452 (the field
                                   //   drawn half a line lower)
    output reg        frame_pulse = 1'b0, // one clock per field, half a line
                                   //   before v_load_pulse, so motion updates
                                   //   land before the objects load
    output reg        v_load_pulse = 1'b0, // one clock per field at the V wrap
                                   //   (object V counter reload)
    output wire [9:0] v_hw         // V count as the board's decodes see it
);

    assign vcount = hw_vcnt[9:1];

    // The board's V chain (IC_F12/H12 7493 + J12) is clocked by H_BLANK
    // falling, when H32 rises: hc 32 of each half-line, not hc 0.  So for
    // the first 32 clocks of a half-line the V decodes still see the previous
    // count, except in half-line 0, which V_RESET (IC_K12) clears at hc 0.
    // hw_vcnt is the half-line index; v_hw is what the V decodes see
    // (playfield ROM address, V_INFO, score rows, mines).
    wire       hc_lt32 = (hcount < 10'd32) ||
                         ((hcount >= 10'd452) && (hcount < 10'd484));
    assign v_hw = (hc_lt32 && (hw_vcnt != 10'd0)) ? (hw_vcnt - 10'd1) : hw_vcnt;

    //=========================================================================
    // COUNTERS - 904-clock line, 521-half-line field; never reset.
    //
    // The half-line tick enters hcount 452 and hcount 0.  With 521 ticks a
    // field, the wrap alternates between the two, as on the board.
    //=========================================================================
    wire tick = (hcount == 10'd451) || (hcount == 10'd903);
    wire wrap = tick && (hw_vcnt == 10'd520);

    always @(posedge clk_pix) begin
        hcount <= (hcount == 10'd903) ? 10'd0 : hcount + 10'd1;

        if (tick) hw_vcnt <= wrap ? 10'd0 : hw_vcnt + 10'd1;
        if (wrap) field   <= ~field;

        // Once-per-field strobes, registered one clock after their trigger
        // so users see settled counts.
        frame_pulse  <= tick && (hw_vcnt == 10'd519);  // entering half-line 520
        v_load_pulse <= wrap;                          // entering half-line 0
    end

    //=========================================================================
    // SYNC AND BLANKING
    //
    // Registered on clk_pix; HSYNC / HBLANK / DE use the next hcount so they
    // line up with the registered hcount.
    //
    // The vertical outputs are latched once per line, at the line start:
    // the MiSTer scaler expects whole-line VSYNC / VBLANK / DE with the field
    // given by VGA_F1, and does the half-line weave itself.  VSYNC-to-VSYNC
    // then alternates 260 / 261 lines, the usual interlace shape, and each
    // field has 252 full DE lines.  Inside the core the raster stays the
    // board's: in the lower field the content row still advances part-way
    // along each line.  Half-lines 0..7 (vertical retrace) carry no DE.
    //=========================================================================
    wire [9:0] hcount_n = (hcount == 10'd903) ? 10'd0 : hcount + 10'd1;
    wire [9:0] vh_n     = !tick ? hw_vcnt
                                : (wrap ? 10'd0 : hw_vcnt + 10'd1);

    reg row_ok = 1'b0;   // per-line DE row gate (latched at each line start)

    always @(posedge clk_pix) begin
        hblank <= (hcount_n < 10'd128);
        hsync  <= (hcount_n >= 10'd32) && (hcount_n < 10'd64);   // COMP_SYNC H part

        // vertical signaling: latched at the line boundary from the value
        // the half-line counter holds as the new line begins
        if (hcount == 10'd903) begin
            vsync  <= (vh_n < 10'd8);
            vblank <= (vh_n >= 10'd512) || (vh_n < 10'd8);
            row_ok <= (vh_n >= 10'd8) && (vh_n < 10'd512);
        end

        de     <= (hcount_n >= 10'd128) && (hcount_n < 10'd902) && row_ok;
    end

endmodule
