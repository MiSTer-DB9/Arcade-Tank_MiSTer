//============================================================================
// Tank (Kee Games / Atari, 1974) - playfield: maze and score digits
//============================================================================
//
// The 2 KB ROM (90-2006, MK28000 at K10, drawn as IC_R10 in the netlist)
// is read through five 74153 muxes (IC_D9/E9/J9/H9/F9).  In the maze band
// (select {V_INFOQ, H_INFOQ} = 11, input C3) the address is:
//
//   A0 H64   A1 H128   A2 H256   A3 H452 (which half of the line)
//   A4 V16   A5 V32    A6 V64    A7 V128   A8 V256
//   A9 the R13 line: which of the ROM's two mazes is drawn
//   A10 = XOR(H_INFOQ, V_INFOQ) = 0
//
// R13 is a pull-up, so the bare board draws block 1 (0x200-0x3FF), the
// original maze; jumper JU1 pulls it low for block 0, a second maze with
// the same outer frame and different inner walls.  maze_sel picks it.
// tank_core muxes this address with the score, tank and motion fetches.
//
// IC_N10 (74165) shifts each ROM byte out at 8 clocks a bit, 64 clocks a
// byte: a load every 64 clocks in the maze band (PFLDQ at H32 rising), and
// in the score band one load per half-line at H256, only while V32 is high,
// so each score shows its 8 glyph rows once.
//
// The IC_J13 latch flips at V16 & V64 (half-line 80) and back at V512, so
// the maze band is half-lines 80..511, with the score band above it.
// v_info here is 1 in the maze band (the board's V_INFOQ; V_INFO itself is
// high in the score band).
//
// PLAYFIELD = NOR(MINEFIELD, ~FIELD, V512) (IC_K13): no walls inside the
// minefield.  tank_core applies that and the end-of-game score flash.
//============================================================================

module playfield (
    input  wire        clk_pix,
    input  wire        reset,
    input  wire [9:0]  hcount,     // 0..903
    input  wire [9:0]  hw_vcnt,    // V count as the decodes see it (v_hw)
    input  wire        de,
    input  wire        maze_sel,   // R13 strap: 0 = original (block 1), 1 = alternate (block 0)

    // ROM interface
    output wire [10:0] rom_addr,
    input  wire [7:0]  rom_data,

    output wire        video,
    output wire        wall,   // raw ROM pixel, not masked by v_info / de
    output wire        v_info_out
);

    //=========================================================================
    // H counter bits within the half-line (a line is two 452-clock halves)
    //=========================================================================

    wire        h452 = (hcount >= 10'd452);
    wire [8:0]  hc_raw = h452 ? (hcount[8:0] - 9'd452) : hcount[8:0];
    wire [8:0]  hc   = (hc_raw > 9'd451) ? 9'd451 : hc_raw;

    //=========================================================================
    // Hardware counter bit aliases
    //=========================================================================

    wire H64   = hc[6];
    wire H128  = hc[7];
    wire H256  = hc[8];
    wire H452  = h452;

    wire V16   = hw_vcnt[4];
    wire V32   = hw_vcnt[5];
    wire V64   = hw_vcnt[6];
    wire V128  = hw_vcnt[7];
    wire V256  = hw_vcnt[8];
    wire V512  = hw_vcnt[9];

    //=========================================================================
    // ROM address in the maze band (74153 C3 inputs, see the header)
    //=========================================================================

    assign rom_addr = {
        1'b0,        // bit 10 (A10 / pin 15): XOR(H_INFOQ,V_INFOQ) = 0 in C3
        ~maze_sel,   // bit 9  (A9  / pin  8): R13 (1 = original maze)
        V256,    // bit 8  (A8  / pin 10): V256
        V128,    // bit 7  (A7  / pin 11): V128
        V64,     // bit 6  (A6  / pin 12): V64
        V32,     // bit 5  (A5  / pin  7): V32
        V16,     // bit 4  (A4  / pin  6): V16
        H452,    // bit 3  (A3  / pin  5): H452
        H256,    // bit 2  (A2  / pin  4): H256
        H128,    // bit 1  (A1  / pin  3): H128
        H64      // bit 0  (A0  / pin  2): H64
    };

    //=========================================================================
    // 74165 shift register (IC_N10)
    //
    // Loads on PFLDQ (the ROM read has one clock of latency) and shifts on
    // H4Q rising, i.e. every 8 clocks.
    //=========================================================================

    reg [7:0] shift_reg;

    // PFLDQ:
    //   maze band:  every 64 clocks, at hc[5:0] == 31 (H32 rising)
    //   score band: once per half-line at hc == 255 (H256 rising), only
    //               while V32 is high (IC_H13.12 = NAND(V_INFO, V32, H256)),
    //               so the 8 glyph rows (V4..V16) are shown once.
    wire score_load_en = !v_info && hw_vcnt[5];   // score mode AND V32=1
    wire pfload  = v_info    ? (hc[5:0] == 6'd31)
                 : score_load_en ? (hc == 9'd255)
                 : 1'b0;
    wire pfshift = (hc[2:0] == 3'd7);

    always @(posedge clk_pix) begin
        if (reset) begin
            shift_reg <= 8'd0;
        end else begin
            if (pfload) begin
                shift_reg <= rom_data;
            end else if (pfshift) begin
                shift_reg <= {shift_reg[6:0], 1'b0};
            end
        end
    end

    //=========================================================================
    // Maze-band latch (IC_J13 NAND latch): set at V16 & V64 (first at
    // half-line 80), cleared at V512.  Set wins if both are active.
    //=========================================================================

    wire v_info_set = V16 & V64;
    wire v_info_rst = V512;

    reg v_info;
    always @(posedge clk_pix) begin
        if (reset)            v_info <= 1'b0;
        else if (v_info_set)  v_info <= 1'b1;
        else if (v_info_rst)  v_info <= 1'b0;
    end

    //=========================================================================
    // Maze video: the shift register's MSB, in the maze band only.
    //=========================================================================

    assign video = (de && v_info) ? shift_reg[7] : 1'b0;
    assign wall  = shift_reg[7];
    assign v_info_out = v_info;

endmodule
