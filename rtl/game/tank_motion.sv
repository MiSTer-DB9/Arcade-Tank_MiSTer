//============================================================================
// tank_motion - one tank's position
//============================================================================
//
// On the board a tank has no position register.  Its X counter (IC_A1/B1/N1,
// 9316s) and Y counter (IC_A2/B2/C2) run continuously with the raster, and
// the tank is drawn where they pass zero.  This is the "slipping counter" of
// the service manual (section 14): while the tank stands still, the motion
// latches (IC_M8/N8 X, IC_M9/N9 Y) are held at a stop code that makes the
// counter's period exactly one line (X) or one field (Y), so its phase - the
// position - stays put.  On a field where the tank moves, the latches load
// the C0 motion byte for its heading and one counter cycle is longer or
// shorter: the phase slips by dx = signed(low nibble) + 1 clocks, and
// dy = high nibble - 8 half-lines.
//
// This module keeps that phase as a position register and adds the same
// dx / dy on each step; tank_object turns it back into counters.  The
// result is the same as the counters (checked in simulation against a
// gate-level model of them: still tanks stay locked, every heading steps
// alike).
//
// MAME's netlist takes HD1 / HD2 from 7474 pin 5 (Q) where the schematic
// uses pin 6 (Q-bar).  That breaks the stop code, so its tanks drift
// diagonally at rest - the failure the service manual describes.
//============================================================================

module tank_motion #(
    parameter [9:0] SPAWN_X = 10'd300,
    parameter [9:0] SPAWN_Y = 10'd200
) (
    input  wire        clk_pix,       // CLOCK1 master clock
    input  wire        reset,         // synchronous reset to the start position
    input  wire        frame_pulse,   // once per field (VLD1)
    input  wire        attractq,      // 0 = attract mode: no movement
    input  wire        startq,        // 0 = new game: back to the start position

    // G01 (from the IC_H14 step divider): high for a field with a step.
    input  wire        g01,

    // C0 motion byte = ROM[0x200 + heading]: the forward step.
    input  wire [7:0]  motion_byte,

    // Bounce: on the board the heading MSB is flipped for the C0 fetch
    // (D4* = D4 ^ BOUNCE), which gives exactly the reversed step.  Here the
    // step is negated, so the tank backs off in the same field.
    input  wire        bounce,

    // Position (the counter phase; see the header).
    output wire [9:0]  pos_x,
    output wire [9:0]  pos_y
);

    //=========================================================================
    // Motion latches (IC_M8/N8 X, IC_M9/N9 Y)
    //
    // At the top of each field the board does, in order:
    //   V_RESET - the BOUNCE latch (IC_A8) updates
    //   VLD1    - the step divider counts and decides G01; the motion
    //             latches load the C0 byte for the heading as it is now
    //   VLD2    - TM1 may then change the heading
    // So a step uses the heading from before that field's turn.  At
    // frame_pulse motion_byte still holds that heading, so it is captured
    // there; the field's G01 is read one clock later (fp_d).
    //=========================================================================
    reg [7:0] c0_byte;   // {VD1..VA1, HD1..HA1} as VLD1 would latch it
    reg       fp_d;

    always @(posedge clk_pix) begin
        fp_d <= frame_pulse;
        if (reset)            c0_byte <= 8'h8F;          // C0 rest code (0,0)
        else if (frame_pulse) c0_byte <= motion_byte;
    end

    //=========================================================================
    // C0 decode: dx = signed(low nibble) + 1, dy = high nibble - 8.  A bounce
    // negates it (the table has ROM[rot ^ 16] = -ROM[rot]).
    //=========================================================================
    wire signed [4:0] dx = $signed({c0_byte[3], c0_byte[3:0]}) + 5'sd1;
    wire signed [4:0] dy = $signed({1'b0,     c0_byte[7:4]}) - 5'sd8;
    wire [9:0] step_x = bounce ? -{{5{dx[4]}}, dx} : {{5{dx[4]}}, dx};
    wire [9:0] step_y = bounce ? -{{5{dy[4]}}, dy} : {{5{dy[4]}}, dy};

    //=========================================================================
    // Position registers, stepped on G01 fields.
    //=========================================================================
    reg [9:0] pos_x_reg;
    reg [9:0] pos_y_reg;

    // Out of bounds: a tank whose 16 x 16 box leaves the maze returns to its
    // start position (the board's OOB, from the tank window meeting the
    // edge of the maze band or the side border).  Limits = the maze area
    // including its outer walls (half-lines 80..511, hcount 160..883) minus
    // the tank size, so a tank bouncing off an outer wall never reaches them.
    localparam [9:0] OOB_Y_MIN = 10'd80,  OOB_Y_MAX = 10'd496;   // 80 ; 511 - 15
    localparam [9:0] OOB_X_MIN = 10'd160, OOB_X_MAX = 10'd868;   // 160 ; 883 - 15

    wire oob_respawn = (pos_y_reg < OOB_Y_MIN) | (pos_y_reg > OOB_Y_MAX)
                     | (pos_x_reg < OOB_X_MIN) | (pos_x_reg > OOB_X_MAX);

    // X and Y take effect at different times, as on the board:
    //   X - the M8/N8 latch holds the code for one counter cycle (IC_L8
    //       clears it at the next line start), so the step shows in the G01
    //       field itself.
    //   Y - the M9/N9 latch holds the code for the whole field, and the Y
    //       counter reloads only at its own TVR (the end of the tank's
    //       window), so the step shows one field later.
    reg [9:0] y_step;
    reg       y_pend;

    always @(posedge clk_pix) begin
        if (reset || ~startq) begin
            // New game: back to the start position.  On the board STARTQ
            // clears the position counters through IC_L9 (HRST1Q / VRST1Q =
            // NAND(STARTQ, NAND(OOB, TANK1))).
            pos_x_reg <= SPAWN_X;
            pos_y_reg <= SPAWN_Y;
            y_pend    <= 1'b0;
        end else if (frame_pulse) begin
            y_pend <= 1'b0;
            if (oob_respawn) begin
                // Out of bounds: the other clear term (OOB & TANK1).  These
                // two are the only position resets.  A destroyed tank is
                // not reset: BLO_UP only flashes the tank and blocks the
                // opponent's fire, so the tank comes back where it died.
                // (tank_core holds g01 low during the tank's own explosion.)
                pos_x_reg <= SPAWN_X;
                pos_y_reg <= SPAWN_Y;
            end else if (y_pend) begin
                pos_y_reg <= pos_y_reg + y_step;   // the previous step's Y
            end
        end else if (fp_d && attractq && g01) begin
            // A G01 field begins: X in clocks, Y in half-lines.
            pos_x_reg <= pos_x_reg + step_x;
            y_step    <= step_y;
            y_pend    <= 1'b1;
        end
    end

    assign pos_x = pos_x_reg;
    assign pos_y = pos_y_reg;

endmodule
