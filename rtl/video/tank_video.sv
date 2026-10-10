//============================================================================
// Tank (Kee Games / Atari, 1974) - the moving objects
//============================================================================
//
// Two tanks, two shells and two shell explosions, each drawn by an object
// generator built on 9316 counters, as on the board:
//
//   tank_object  - 16 x 16 tank, shape from the ROM (C2 fetch)
//   shell_object - 4 x 4 solid shell (SHELL1 / SHELL2)
//   blast_object - 16 x 16 explosion pattern where the shell stopped
//                  (BLAST1 / BLAST2)
//
// The tank shapes are fetched at the start of each line: hcount 0-7 for
// tank 1, 8-15 for tank 2.  Shells and explosions do not use the ROM.
//============================================================================

module tank_video (
    input  wire        clk_pix,
    input  wire        reset,

    input  wire [9:0]  hcount,
    input  wire [9:0]  hw_vcnt,
    input  wire        v_load_pulse,  // once per field, at the V wrap

    // Tank 1
    input  wire [4:0]  p1_rot,
    input  wire [9:0]  p1_x,
    input  wire [9:0]  p1_y,

    // Tank 2
    input  wire [4:0]  p2_rot,
    input  wire [9:0]  p2_x,
    input  wire [9:0]  p2_y,

    // Shell 1
    input  wire [9:0]  s1_x,
    input  wire [9:0]  s1_y,
    input  wire        s1_flight,
    input  wire        s1_blast,

    // Shell 2
    input  wire [9:0]  s2_x,
    input  wire [9:0]  s2_y,
    input  wire        s2_flight,
    input  wire        s2_blast,

    // FLASH (IC_A12, ~5 Hz) animates the explosion pattern.
    input  wire        flash,

    // Shared ROM port
    output wire [10:0] rom_addr,
    input  wire [7:0]  rom_data,

    output wire        p1_video,
    output wire        p2_video,
    output wire        s1_video,
    output wire        s2_video,
    output wire        b1_video,
    output wire        b2_video,
    // WINDO1 / WINDO2: high inside each tank's 16 x 16 box.
    output wire        p1_window,
    output wire        p2_window,
    // TVR1 / TVR2: each tank's V counter terminal state (shell-arm clear).
    output wire        p1_tvr,
    output wire        p2_tvr
);

    //=========================================================================
    // Tank 1 - shape fetch at hcount 0-7
    //=========================================================================
    wire [10:0] p1_object_rom_addr;

    tank_object #(
        .FETCH_A_START (10'd0),
        .FETCH_A_END   (10'd3),
        .FETCH_B_START (10'd4),
        .FETCH_B_END   (10'd7),
        .LATCH_A_AT    (10'd2),
        .LATCH_B_AT    (10'd6)
    ) u_tank1_object (
        .clk_pix       (clk_pix),
        .reset         (reset),
        .hcount        (hcount),
        .hw_vcnt       (hw_vcnt),
        .v_load_pulse  (v_load_pulse),
        .rot           (p1_rot),
        .x             (p1_x),
        .y             (p1_y),
        .rom_data      (rom_data),
        .rom_addr      (p1_object_rom_addr),
        .video         (p1_video),
        .window        (p1_window),
        .tvr           (p1_tvr)
    );

    //=========================================================================
    // Tank 2 - shape fetch at hcount 8-15
    //=========================================================================
    wire [10:0] p2_object_rom_addr;

    tank_object #(
        .FETCH_A_START (10'd8),
        .FETCH_A_END   (10'd11),
        .FETCH_B_START (10'd12),
        .FETCH_B_END   (10'd15),
        .LATCH_A_AT    (10'd10),
        .LATCH_B_AT    (10'd14)
    ) u_tank2_object (
        .clk_pix       (clk_pix),
        .reset         (reset),
        .hcount        (hcount),
        .hw_vcnt       (hw_vcnt),
        .v_load_pulse  (v_load_pulse),
        .rot           (p2_rot),
        .x             (p2_x),
        .y             (p2_y),
        .rom_data      (rom_data),
        .rom_addr      (p2_object_rom_addr),
        .video         (p2_video),
        .window        (p2_window),
        .tvr           (p2_tvr)
    );

    //=========================================================================
    // Shells - drawn in flight (FIRE1 / FIRE2 high)
    //=========================================================================
    shell_object u_shell1_object (
        .clk_pix (clk_pix),
        .reset   (reset),
        .hcount  (hcount),
        .hw_vcnt (hw_vcnt),
        .v_load_pulse (v_load_pulse),
        .x       (s1_x),
        .y       (s1_y),
        .active  (s1_flight),
        .video   (s1_video)
    );

    shell_object u_shell2_object (
        .clk_pix (clk_pix),
        .reset   (reset),
        .hcount  (hcount),
        .hw_vcnt (hw_vcnt),
        .v_load_pulse (v_load_pulse),
        .x       (s2_x),
        .y       (s2_y),
        .active  (s2_flight),
        .video   (s2_video)
    );

    //=========================================================================
    // Explosions - drawn while EXPL1 / EXPL2 is high, where the shell
    // stopped (the shell stops moving when its flight ends).  One window
    // frames both a shell and its explosion; the shell is columns 4-7,
    // rows 8-11 of it, so the explosion window starts at the shell
    // position - (4, 8).
    //=========================================================================
    wire [9:0] b1_x = s1_x - 10'd4;
    wire [9:0] b1_y = s1_y - 10'd8;
    wire [9:0] b2_x = s2_x - 10'd4;
    wire [9:0] b2_y = s2_y - 10'd8;

    blast_object u_blast1_object (
        .clk_pix       (clk_pix),
        .reset         (reset),
        .hcount        (hcount),
        .hw_vcnt       (hw_vcnt),
        .v_load_pulse  (v_load_pulse),
        .x             (b1_x),
        .y             (b1_y),
        .active        (s1_blast),
        .flash         (flash),
        .video         (b1_video)
    );

    blast_object u_blast2_object (
        .clk_pix       (clk_pix),
        .reset         (reset),
        .hcount        (hcount),
        .hw_vcnt       (hw_vcnt),
        .v_load_pulse  (v_load_pulse),
        .x             (b2_x),
        .y             (b2_y),
        .active        (s2_blast),
        .flash         (flash),
        .video         (b2_video)
    );

    //=========================================================================
    // ROM address: each tank owns its own fetch slot.
    //=========================================================================
    assign rom_addr = (hcount >= 10'd0 && hcount <= 10'd7)  ? p1_object_rom_addr
                    : (hcount >= 10'd8 && hcount <= 10'd15) ? p2_object_rom_addr
                    : 11'd0;

endmodule
