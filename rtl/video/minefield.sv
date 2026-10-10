//============================================================================
// Tank (Kee Games / Atari, 1974) - the minefield
//============================================================================
//
// The Board II mine circuit.  A mine is drawn where all of these meet:
//
//   1. MINEFIELD zone -- inside both the MEH and MEV latches
//   2. MINE_MATRIX    -- a repeating dot pattern (NOR of CHECKERBOARD and
//                        SQUARES: IC_D7 7402, IC_F13 7486, IC_A10)
//   3. FIELD          -- the raw ROM bit; inside the zone the ROM holds the
//                        mine layout instead of walls
//   4. IC_F7 gate     -- the mine has not been set off
//
//----------------------------------------------------------------------------
// MEH SR latch (Mine Enable Horizontal)  --  IC_B13 (7400) + IC_C13 (7410)
//
//   SET#  = NAND(H452Q, H256, H128)   fires when hc[8]=hc[7]=1 in 1st half
//           -> hcount ~384..451
//   RESET# = NAND(H452, H128, H16)    fires when hcount in 2nd half with
//            hc[7]=hc[4]=1
//           -> hcount ~596..611  (first opportunity)
//
//   MEH is HIGH for hcount ~384..595   (212 clocks)
//
//----------------------------------------------------------------------------
// MEV SR latch (Mine Enable Vertical)  --  IC_B14 (7400) + IC_H13 (7410)
//
//   SET#   = NAND(V32, V128, V256Q)   fires when hw_vcnt[5]=hw_vcnt[7]=1,
//            hw_vcnt[8]=0
//           -> hw_vcnt ~160..191 and 224..255
//   RESET# = NAND(IC_A11.11, V128, V32)
//            where IC_A11.11 = AND(V256, H_SYNC)
//            When V256=1 and H_SYNC=0 (active scan):  RESET# fires when
//            hw_vcnt[7]=hw_vcnt[5]=1, hw_vcnt[8]=1
//           -> hw_vcnt ~416..447 and 480..511
//
//   When V256=0: RESET# is held HIGH (because IC_A11.11=0), so
//   only SET# can drive the latch; SET wins by default.
//   MEV is HIGH for hw_vcnt ~160..415   (256 half-lines)
//
//----------------------------------------------------------------------------
// MINEFIELD = NOR(MEVQ, MEHQ) = MEV & MEH  (via IC_A13 7402 gate 2)
//
//----------------------------------------------------------------------------
// Mine dot pattern  --  IC_D7 (7402), IC_F13 (7486), IC_A10 (7400):
//
//   SQUARES     = NAND(V8, H8) = ~(hw_vcnt[3] & hc[3])     [IC_A10 gate 4]
//   CHECKERBOARD = XOR(V4,V2,H4,H2)
//               = hw_vcnt[2]^hw_vcnt[1]^hc[2]^hc[1]         [IC_F13 XOR chain]
//   MINE_MATRIX = NOR(CHECKERBOARD, SQUARES)               [IC_D7 gate 1]
//               = ~CHECKERBOARD & ~SQUARES
//               = ~(hw_vcnt[2]^hw_vcnt[1]^hc[2]^hc[1])  &  (hw_vcnt[3] & hc[3])
//
//----------------------------------------------------------------------------
// IC_F7 is a Signetics 8277 dual 8-bit shift register: a 16-bit ring that
// remembers which mines have been set off.
//============================================================================

module minefield (
    input  wire        clk_pix,
    input  wire        reset,
    input  wire [9:0]  hcount,    // from video_sync, 0..903
    input  wire [9:0]  hw_vcnt,   // V count as the decodes see it (v_hw)
    input  wire        hsync,     // internal H_SYNC net (hcount 0..31), for MEV reset
    input  wire        de,        // data enable
    input  wire        field,     // raw FIELD bit from K10 (1 = mine-mask pixel)
    output wire        video,     // 1 = mine pixel here
    output wire        zone,      // 1 = inside MEH/MEV minefield rectangle
    input  wire        mine_hit,  // 1 when a tank hits a mine
    output wire        f7_clk_out,// IC_F7 shift clock (also clears the MTK latches)
    input  wire        startq     // 8277 RESET: a new game restores every mine
);

    //=========================================================================
    // H counter bits within the half-line (as in playfield.sv)
    //=========================================================================
    wire        h452 = (hcount >= 10'd452);
    wire [8:0]  hc   = h452 ? (hcount[8:0] - 9'd452) : hcount[8:0];

    //=========================================================================
    // Hardware counter bit aliases
    //=========================================================================
    wire H16   = hc[4];
    wire H128  = hc[7];
    wire H256  = hc[8];
    wire H452  = h452;
    wire H452Q = ~h452;

    wire V32   = hw_vcnt[5];
    wire V128  = hw_vcnt[7];
    wire V256  = hw_vcnt[8];
    wire V256Q = ~hw_vcnt[8];

    //=========================================================================
    // MEH SR latch  (Mine Enable Horizontal)
    //
    // NAND SR latch built from IC_B13 (7400) gates 1 & 2:
    //   MEH  = NAND(SET#,   MEHQ)
    //   MEHQ = NAND(MEH,    RESET#)
    //
    // Synchronous here; SET wins if both are active.
    //=========================================================================
    wire meh_set_n   = ~(H452Q & H256 & H128);   // IC_C13 gate 1 output
    wire meh_reset_n = ~(H452  & H128 & H16);    // IC_C13 gate 3 output

    reg meh;
    always @(posedge clk_pix) begin
        if (reset)            meh <= 1'b0;
        else if (!meh_set_n)  meh <= 1'b1;
        else if (!meh_reset_n)meh <= 1'b0;
    end

    //=========================================================================
    // MEV SR latch  (Mine Enable Vertical)
    //
    // SET#  = IC_H13 gate 2 = NAND(V32, V128, V256Q)
    // RESET# = IC_H13 gate 3 = NAND(IC_A11.11, V128, V32)
    //   where IC_A11.11 = AND(V256, H_SYNC)  (IC_A11 gate 4, a 7408)
    //
    // So RESET# fires only during the HSYNC pulse when V256=V128=V32=1.
    //=========================================================================
    wire mev_set_n   = ~(V32 & V128 & V256Q);          // IC_H13 gate 2
    wire mev_reset_n = ~(V256 & hsync & V128 & V32);    // IC_H13 gate 3 (full)

    reg mev;
    always @(posedge clk_pix) begin
        if (reset)            mev <= 1'b0;
        else if (!mev_set_n)  mev <= 1'b1;
        else if (!mev_reset_n)mev <= 1'b0;
    end

    //=========================================================================
    // MINEFIELD = NOR(MEVQ, MEHQ) = MEV & MEH  (IC_A13 7402, gate 2)
    //=========================================================================
    wire minefield = mev & meh;
    assign zone = minefield;

    //=========================================================================
    // Mine dot pattern  (MINE_MATRIX from IC_D7 7402 gate 1)
    //
    //   MINE_MATRIX = ~CHECKERBOARD & ~SQUARES
    //               = ~(hw_vcnt[2]^hw_vcnt[1]^hc[2]^hc[1])
    //                  & (hw_vcnt[3] & hc[3])
    //=========================================================================
    wire mine_matrix = (hw_vcnt[3] & hc[3]) &
                       ~(hw_vcnt[2] ^ hw_vcnt[1] ^ hc[2] ^ hc[1]);

    //=========================================================================
    // IC_F7 (Signetics 8277) -- dual 8-bit shift register
    //
    // 8277 pin use in Tank (Dual 8-bit Shift Register):
    //   pin  1 RESET  <- STARTQ (active low reset)
    //   pin  3 Q7A    -> pin 13 DSB
    //   pin  4 DSA    <- IC_J7.10 (NOR of hit latch and Q7B)
    //   pin  5 D1A    <- GND
    //   pin  6 D0A    <- VCC
    //   pin  9 CLK    <- IC_A11.8 = MEV & V8
    //   pin 11 D0B    <- GND
    //   pin 12 D1B    <- VCC
    //   pin 14 Q7B    -> IC_J7.9
    //
    // Each 8277 input mux takes D0 when DS = 0, D1 when DS = 1:
    //   register B: DSB = Q7A, D0B = 0, D1B = 1  ->  B_in = Q7A
    //   register A: DSA = J7.10, D0A = 1, D1A = 0  ->  A_in = ~J7.10
    //   J7.10 = NOR(mine_hit, Q7B)  ->  A_in = mine_hit | Q7B
    // So the two registers form a 16-bit ring, shifted once per 16
    // half-lines of the minefield.  A tank on a mine injects a 1, which
    // comes round each time the beam reaches that mine's band and blanks
    // it until the next game.
    //=========================================================================
    wire f7_clk = mev & hw_vcnt[3];   // 16 shifts per field

    reg       f7_clk_d;
    reg [7:0] f7_a;
    reg [7:0] f7_b;

    wire f7_q7a   = f7_a[7];
    wire f7_q7b   = f7_b[7];
    
    // IC_J7.10 = NOR(IC_K7.8, Q7B), K7.8 = NAND(MTK1Q, MTK2Q) = MTK1 | MTK2.
    // The same node feeds DSA and gates the mine video (IC_J7.10 ->
    // IC_E7.5), so a mine disappears the moment it is hit, and every mine
    // drawn before the next shift (which clears the MTK latch) blanks with
    // it for that moment.
    wire f7_j7_10 = ~(mine_hit | f7_q7b);
    wire f7_gate  = f7_j7_10;

    // A shifts into B, B into A (A_in = ~DSA = mine_hit | Q7B).
    wire f7_a_in = ~f7_j7_10;
    wire f7_b_in = f7_q7a;
    
    assign f7_clk_out = f7_clk;

    always @(posedge clk_pix) begin
        if (reset || ~startq) begin
            f7_clk_d <= 1'b0;
            f7_a     <= 8'd0;
            f7_b     <= 8'd0;
        end else begin
            f7_clk_d <= f7_clk;

            // shift on the rising edge
            if (f7_clk && !f7_clk_d) begin
                f7_a <= {f7_a[6:0], f7_a_in};
                f7_b <= {f7_b[6:0], f7_b_in};
            end
        end
    end

    //=========================================================================
    // Mine video output
    //
    // MINE = AND(MINEFIELD, MINE_MATRIX, FIELD, J7.10)  (IC_E7).  Inside
    // the zone, the ROM's FIELD bits lay out the diamond of mines.
    //=========================================================================
    assign video = de & minefield & mine_matrix & f7_gate & field;

endmodule
