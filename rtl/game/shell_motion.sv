//============================================================================
// shell_motion - one shell's position
//============================================================================
//
// The board's shell path works like a tank's (see tank_motion.sv):
//
//   velocity latches IC_D1/E1 (X), IC_D2/E2 (Y): load the C0 motion byte
//     on NAND(VLD1, FIRE1Q), which stops toggling once the shell is fired,
//     so the shell keeps the heading the tank had when it fired;
//   position counters IC_H2/J2 (X) and IC_H1/J1/F1 (Y): step once per field
//     (HMCE) while the shell flies.
//
// As in tank_motion, the counter phase is kept as a position register.
// The flight and explosion timers are in tank_shells.
//============================================================================

module shell_motion (
    input  wire        clk_pix,
    input  wire        reset,
    input  wire        frame_pulse,    // once per field (VLD1)

    // Start position when the shell is fired (tank position + offset)
    input  wire        fire_edge,      // one clock as the shell is fired
    input  wire [9:0]  spawn_x,
    input  wire [9:0]  spawn_y,

    // C0 motion byte of the firing tank, captured at fire_edge
    input  wire [7:0]  motion_byte,

    // HMCE: high while the shell flies (one step per field); low during the
    // explosion, which stays where the shell stopped.
    input  wire        hmce,

    output wire [9:0]  pos_x,
    output wire [9:0]  pos_y
);

    //=========================================================================
    // Velocity latches (IC_D1/E1 X, IC_D2/E2 Y): clocked by
    // NAND(VLD1, FIRE1Q), which stays high once the shell is fired, so the
    // value captured at fire_edge holds for the whole flight.
    //=========================================================================
    reg [3:0] h_nib;   // IC_D1/E1 outputs = ROM_D0..D3
    reg [3:0] v_nib;   // IC_D2/E2 outputs = ROM_D4..D7

    always @(posedge clk_pix) begin
        if (reset) begin
            h_nib <= 4'hF;     // C0 rest code (no motion)
            v_nib <= 4'h8;
        end else if (fire_edge) begin
            h_nib <= motion_byte[3:0];
            v_nib <= motion_byte[7:4];
        end
    end

    //=========================================================================
    // C0 decode (direction table at ROM 0x200-0x21F), as in tank_motion.
    //=========================================================================
    wire signed [4:0] dx = $signed({h_nib[3], h_nib[3:0]}) + 5'sd1;
    wire signed [4:0] dy = $signed({1'b0,    v_nib[3:0]}) - 5'sd8;

    //=========================================================================
    // Position (the IC_H2/J2 and IC_H1/J1/F1 counter phase): set to the
    // firing tank's position when fired, then stepped once per field.
    //=========================================================================
    reg [9:0] pos_x_reg;
    reg [9:0] pos_y_reg;

    always @(posedge clk_pix) begin
        if (reset) begin
            pos_x_reg <= 10'd0;
            pos_y_reg <= 10'd0;
        end else if (fire_edge) begin
            pos_x_reg <= spawn_x;
            pos_y_reg <= spawn_y;
        end else if (frame_pulse && hmce) begin
            // X in clocks, Y in half-lines (the Y counter ticks twice a
            // line), as for the tanks.
            pos_x_reg <= pos_x_reg + {{5{dx[4]}}, dx};
            pos_y_reg <= pos_y_reg + {{5{dy[4]}}, dy};
        end
    end

    assign pos_x   = pos_x_reg;
    assign pos_y   = pos_y_reg;

endmodule
