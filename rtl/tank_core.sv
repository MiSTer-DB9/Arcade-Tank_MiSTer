//============================================================================
// Tank (Kee Games / Atari, 1974) - the two game boards
//============================================================================
//
// Top of the game logic: sync and raster counters, the shared 2 KB ROM,
// controls, tank and shell motion, the object generators, maze and mines,
// collisions and scoring, the game timer and coin logic, sound, and the
// resistor-network video mixer.  IC names (IC_xx) follow the Board I / II
// schematics and MAME's netlist (nl_tank.cpp).
//
// Naming note: the core's tank 1 / p1 is the BLACK tank (left), tank 2 / p2
// the WHITE tank (right).  The netlist numbers them the other way round
// (its TANK1 is the white tank); the screen matches the cabinet.
//============================================================================

module tank_core (
    input  wire         clk_pix,     // 14.318181 MHz pixel clock (from PLL)
    input  wire         reset,       // active-high reset

    // ioctl ROM download interface (from hps_io via Arcade-Tank.sv)
    input  wire         ioctl_download,
    input  wire         ioctl_wr,
    input  wire [26:0]  ioctl_addr,  // 27-bit HPS address, truncated to 11 bits internally
    input  wire [7:0]   ioctl_dout,

    output wire         hsync,       // horizontal sync (active high)
    output wire         vsync,       // vertical sync   (active high)
    output wire         hblank,      // horizontal blanking
    output wire         vblank,      // vertical blanking
    output wire         de,          // data enable
    output wire [7:0]   video_r,     // red video output
    output wire [7:0]   video_g,     // green video output
    output wire [7:0]   video_b,     // blue video output

    // Joysticks
    input  wire [31:0]  joystick_0,
    input  wire [31:0]  joystick_1,

    // OSD volume controls (0 = Max .. 7 = Mute)
    input  wire [2:0]   master_vol,
    input  wire [2:0]   shot_vol,
    input  wire [2:0]   boom_vol,
    input  wire         cab_eq,      // 1 = cabinet-speaker EQ on engine
    input  wire         maze_sel,    // 0 = original maze (ROM block 1), 1 = alternate (block 0)
    input  wire         game_time_120, // 0 = 60 s game (factory 25c default), 1 = 120 s (50c)

    // Operator Adjust page (each 0 = the shipped factory behavior)
    input  wire [2:0]   fire1_range, // FIRE1_ADJUST 50k pot position (the WHITE/right
                                     // tank's missile range; black is pre-set)
    input  wire [2:0]   play_pot,    // PLAYTIME 1M rheostat position
    input  wire [2:0]   putt_trim,   // MOTOR*_VOL2 putt-rate trim position
    input  wire [1:0]   volpot_trim, // MOTOR*_VOL control-swing position

    // Interlace field flag (VGA_F1): 1 = the field drawn half a line lower
    output wire         field,

    // Audio output (signed 16-bit)
    output wire [15:0]  audio_l,
    output wire [15:0]  audio_r
);

    //=========================================================================
    // VIDEO SYNC (Board II H and V counter chains)
    //
    // 904 clocks a line, 521 half-lines a field (260.5 lines, 60.80 Hz).
    // The field boundary alternates between hcount 0 and hcount 452, so the
    // once-per-field strobes come from video_sync rather than from a fixed
    // (hcount, vcount) decode: frame_pulse half a line before the V wrap,
    // v_load_pulse at the wrap (object V counter reload).
    //=========================================================================

    wire [9:0] hcount;    // clock within the line, 0..903
    wire [9:0] hw_vcnt;   // half-line index 0..520 (field structure)
    wire [9:0] v_hw;      // V count as the board's V decodes see it (steps
                          // at hc 32, see video_sync)
    wire sync_frame_pulse;   // strobes from the free-running chain
    wire sync_v_load_pulse;

    video_sync u_video_sync (
        .clk_pix      (clk_pix),
        .hsync        (hsync),
        .vsync        (vsync),
        .hblank       (hblank),
        .vblank       (vblank),
        .de           (de),
        .hcount       (hcount),
        .vcount       (),
        .hw_vcnt      (hw_vcnt),
        .field        (field),
        .frame_pulse  (sync_frame_pulse),
        .v_load_pulse (sync_v_load_pulse),
        .v_hw         (v_hw)
    );

    //=========================================================================
    // GAME RESET, aligned to the raster
    //
    // video_sync never resets (the board's H/V chains have no reset, and a
    // running sync keeps the scaler locked).  The game logic is reset by the
    // MiSTer reset, but its release waits until the raster reaches hcount 0,
    // half-line 0 of a field-0 field (a V wrap at hcount 903 only ends a
    // field-1 field), up to two fields (~33 ms).  Every game decode then
    // starts from the same raster point; released mid-field, the object
    // counters would draw a sprite fragment for the rest of that field.
    //
    // frame_pulse / v_load_pulse are gated with reset_game.  The
    // v_load_pulse of the release cycle itself passes, so the object V
    // counters load at once and the first field already draws the objects.
    //=========================================================================
    reg  reset_game = 1'b1;
    wire raster_atzero = (hcount == 10'd903) && (hw_vcnt == 10'd520);
    always @(posedge clk_pix) begin
        if (reset)              reset_game <= 1'b1;
        else if (raster_atzero) reset_game <= 1'b0;
    end

    wire frame_pulse  = sync_frame_pulse  & ~reset_game;
    wire v_load_pulse = sync_v_load_pulse & ~reset_game;

    //=========================================================================
    // SHARED ROM (90-2006 at K10: maze, score digits, tank shapes, motion)
    //=========================================================================
    wire [10:0] pf_rom_addr;
    wire [10:0] tank_rom_addr;
    wire [10:0] mux_rom_addr;
    wire [7:0]  rom_data;
    wire        v_info;      // 1 = maze band (hardware V_INFOQ), from u_playfield

    // The ROM is time-shared along each line:
    //   hcount 0-15    : C2 tank shape fetch (tank 1: 0-7, tank 2: 8-15)
    //   hcount 440-447 : C0 motion table (tank 1, then tank 2)
    //   elsewhere      : C3 maze, or C1 score digits above the maze band
    // The tank fetch sits at the start of the line, outside the area where
    // tanks are drawn, so a fetch never lands inside a sprite.
    wire        motion_rom_en = (hcount >= 10'd440 && hcount <= 10'd447);
    wire        tank_rom_en   = (hcount <= 10'd15);

    // C0 motion address = ROM 0x200 + rotation (the V256=V128=V64=0 table block)
    wire [10:0] motion_rom_addr = (hcount <= 10'd443)
                                ? (11'h200 | {6'd0, p1_rot})
                                : (11'h200 | {6'd0, p2_rot});

    // C1 score address (74153 muxes, select {V_INFOQ=0, H_INFOQ=1}):
    //
    //   A10 = XOR(H_INFOQ, V_INFOQ) = 1  (IC_E8): the digits are at 0x400-0x5FF
    //   A9  = GND (IC_D9 upper mux pin5 = GND in C1) = 0
    //   A8  = SCRF (IC_D9 lower mux pin11, score bit5)
    //   A7  = SCRE (IC_E9 upper mux pin5,  score bit4)
    //   A6  = SCRD (IC_E9 lower mux pin11, score bit3)
    //   A5  = SCRC (IC_J9 upper mux pin5,  score bit2)
    //   A4  = SCRB (IC_J9 lower mux pin11, score bit1)
    //   A3  = SCRA (IC_H9 upper mux pin5,  score bit0 / LSB)
    //   A2  = V16  (IC_H9 lower mux pin11, v_hw[4])
    //   A1  = V8   (IC_F9 upper mux pin5,  v_hw[3])
    //   A0  = V4   (IC_F9 lower mux pin11, v_hw[2])
    //
    // The 9322 muxes IC_D10/E10 select the left score in the left half of
    // the line and the right score in the right half.
    wire [5:0] active_score = (hcount < 10'd452) ? p1_score : p2_score;
    wire [10:0] score_rom_addr = {
        1'b1,          // A10: XOR(H_INFOQ=1, V_INFOQ=0) = 1 in C1 mode
        1'b0,          // A9:  GND in C1 (IC_D9 upper mux C1 pin = GND)
        active_score,  // A8..A3: SCRF..SCRA (6-bit score counter)
        v_hw[4],       // A2: V16
        v_hw[3],       // A1: V8
        v_hw[2]        // A0: V4
    };

    assign mux_rom_addr = motion_rom_en ? motion_rom_addr
                        : tank_rom_en   ? tank_rom_addr
                        : (!v_info)     ? score_rom_addr
                        :                 pf_rom_addr;

    // Latch the fetched C0 bytes (BRAM read has 1-cycle latency).
    reg [7:0] p1_motion_byte;
    reg [7:0] p2_motion_byte;
    always @(posedge clk_pix) begin
        if (hcount == 10'd442) p1_motion_byte <= rom_data;
        if (hcount == 10'd446) p2_motion_byte <= rom_data;
    end

    dpram_2k8 u_rom (
        .clk_a  (clk_pix),
        .wr_a   (ioctl_wr),
        .addr_a (ioctl_addr[10:0]),
        .din_a  (ioctl_dout),

        .clk_b  (clk_pix),
        .addr_b (mux_rom_addr),
        .dout_b (rom_data)
    );

    //=========================================================================
    // TANK CONTROLS - rotation, speed, fire, motion-rate gate (G01/G02)
    //=========================================================================

    wire [4:0] p1_rot, p2_rot;
    wire       p1_acc, p1_stop;
    wire       p2_acc, p2_stop;
    wire [2:0] p1_speed, p2_speed;
    wire       p1_g01,  p2_g01;
    wire       p1_fire, p2_fire;
    wire       p1_wall_hit, p2_wall_hit;
    wire       p1_bounce, p2_bounce;     // one-frame collision reverse -> tank_motion
    wire       hit1_lat, hit2_lat;       // IC_J8 HIT latches -> IC_H11 turn kick

    // The board's control counters (rotation 74193 + 74107, speed 7493,
    // step divider 9316), rebuilt on one clock with enables.
    tank_controls_hw u_tank_controls (
        .clk_pix     (clk_pix),
        .reset       (reset_game),
        .joystick_0  (joystick_0),
        .joystick_1  (joystick_1),
        .frame_pulse (frame_pulse),
        .attractq    (attractq_reg),
        .startq      (startq_wire),
        .p1_wall_hit (p1_wall_hit),
        .p2_wall_hit (p2_wall_hit),
        .hit1_lat    (hit1_lat),
        .hit2_lat    (hit2_lat),
        .p1_rot      (p1_rot),
        .p1_acc      (p1_acc),
        .p1_stop     (p1_stop),
        .p1_speed    (p1_speed),
        .p1_g01      (p1_g01),
        .p1_fire     (p1_fire),
        .p2_rot      (p2_rot),
        .p2_acc      (p2_acc),
        .p2_stop     (p2_stop),
        .p2_speed    (p2_speed),
        .p2_g01      (p2_g01),
        .p2_fire     (p2_fire),
        .p1_bounce   (p1_bounce),
        .p2_bounce   (p2_bounce)
    );

    //=========================================================================
    // TANK MOTION (see tank_motion.sv)
    //=========================================================================

    wire [9:0] p1_x, p1_y, p2_x, p2_y;
    wire       p1_revive, p2_revive;         // BLO_UP falling edge: the tank comes back where it died

    // The core holds a destroyed tank still during its explosion (BLO_UP).
    // The board has no such gate (see tank_motion.sv); the core adds it
    // because its exploding tank, drawn FLASH-inverted for the full two
    // seconds, would otherwise drift into walls and mines and set them off
    // (see tank_collision_hw.sv).
    wire p1_g01_active = p1_g01 & ~blo_up1;
    wire p2_g01_active = p2_g01 & ~blo_up2;

    // Start positions: black tank upper left, white tank lower right, as in
    // the operator manual and cabinet photos, placed clear of the walls in
    // both mazes.
    tank_motion #(.SPAWN_X(10'd300), .SPAWN_Y(10'd166)) u_tank1_motion (   // P1 upper-left
        .clk_pix     (clk_pix),
        .reset       (reset_game),
        .frame_pulse (frame_pulse),
        .attractq    (attractq_reg),
        .startq      (startq_wire),
        .g01         (p1_g01_active),
        .bounce      (p1_bounce),
        .motion_byte (p1_motion_byte),
        .pos_x       (p1_x),
        .pos_y       (p1_y)
    );

    tank_motion #(.SPAWN_X(10'd626), .SPAWN_Y(10'd432)) u_tank2_motion (   // P2 lower-right
        .clk_pix     (clk_pix),
        .reset       (reset_game),
        .frame_pulse (frame_pulse),
        .attractq    (attractq_reg),
        .startq      (startq_wire),
        .g01         (p2_g01_active),
        .bounce      (p2_bounce),
        .motion_byte (p2_motion_byte),
        .pos_x       (p2_x),
        .pos_y       (p2_y)
    );

    //=========================================================================
    // TANK SHELLS - flight and explosion one-shots (IC_C9 / IC_C8 9602).
    // Shell position is in shell_motion below.
    //=========================================================================

    wire       tank1_tvr, tank2_tvr; // TVR1/TVR2: tank V counter terminal state (tank_video)
    wire       s1_flight, s2_flight;
    wire       s1_blast,  s2_blast;
    wire       p1_boom,   p2_boom;
    wire       s1_fire_edge, s2_fire_edge;
    wire       s1_hmce,   s2_hmce;
    wire       s1_hit, s2_hit;  // driven by tank_collision_hw

    // A tank cannot fire while its OPPONENT is exploding (operator manual:
    // until the flashing stops, the opponent cannot fire).  The fire-arm
    // clear is the other tank's BLO_UP (nl_tank.cpp):
    //   shell 1: CLR = NOR(BLO_UP2, SRS1)   (IC_N7 -> IC_A15.1)
    //   shell 2: CLR = NOR(BLO_UP1, SRS2)   (IC_N7 -> IC_A15.13)
    // A tank CAN fire while it is itself exploding: its own BLO_UP has no
    // path to its shell.  SRS is a shell-lifecycle term (see tank_shells).

    tank_shells u_tank_shells (
        .clk_pix      (clk_pix),
        .reset        (reset_game),
        .frame_pulse  (frame_pulse),
        .fire1_range  (fire1_range),
        .attractq     (attractq_reg),
        .hmce_tick    (v_load_pulse),   // HMCE: once per field at the field top
        .blo_up1      (blo_up1),
        .blo_up2      (blo_up2),
        .tvr1         (tank1_tvr),
        .tvr2         (tank2_tvr),
        .p1_fire      (p1_fire),
        .s1_hit       (s1_hit),
        .s1_flight    (s1_flight),
        .s1_blast     (s1_blast),
        .p1_boom      (p1_boom),
        .s1_fire_edge (s1_fire_edge),
        .s1_hmce      (s1_hmce),
        .p2_fire      (p2_fire),
        .s2_hit       (s2_hit),
        .s2_flight    (s2_flight),
        .s2_blast     (s2_blast),
        .p2_boom      (p2_boom),
        .s2_fire_edge (s2_fire_edge),
        .s2_hmce      (s2_hmce)
    );

    //=========================================================================
    // SHELL MOTION - velocity latch + position counters per shell
    //=========================================================================

    wire [9:0] s1_x, s1_y, s2_x, s2_y;

    // Where a shell appears (measured on the netlist): its 16 x 16 window
    // starts at the tank's window + 1 clock, and the visible 4 x 4 shell is
    // at columns 4-7, rows 8-11 of it.  The core's shell position is the
    // visible shell, so it starts at tank + (5, 8).
    shell_motion u_shell1_motion (
        .clk_pix     (clk_pix),
        .reset       (reset_game),
        .frame_pulse (frame_pulse),
        .fire_edge   (s1_fire_edge),
        .spawn_x     (p1_x + 10'd5),
        .spawn_y     (p1_y + 10'd8),
        .motion_byte (p1_motion_byte),
        .hmce        (s1_hmce),
        .pos_x       (s1_x),
        .pos_y       (s1_y)
    );

    shell_motion u_shell2_motion (
        .clk_pix     (clk_pix),
        .reset       (reset_game),
        .frame_pulse (frame_pulse),
        .fire_edge   (s2_fire_edge),
        .spawn_x     (p2_x + 10'd5),
        .spawn_y     (p2_y + 10'd8),
        .motion_byte (p2_motion_byte),
        .hmce        (s2_hmce),
        .pos_x       (s2_x),
        .pos_y       (s2_y)
    );

    //=========================================================================
    // TANK VIDEO - tank_object x2 + shell_object x2 + blast_object x2
    //=========================================================================

    wire tank1_video, tank2_video;
    wire tank1_window, tank2_window;   // WINDO1/WINDO2 sprite-box flags
    wire shell1_video, shell2_video;
    wire blast1_video, blast2_video;

    // A bounce never flips the drawn tank.  The flipped heading bit
    // D4* = XOR(D4, BOUNCE) feeds only the C0 motion fetch (IC_J9 pin 10);
    // the C2 shape fetch takes the plain D4 (IC_H9 pin 4).  So a bouncing
    // tank steps backward while still facing forward (the reversal itself
    // is in tank_motion).

    tank_video u_tank_video (
        .clk_pix      (clk_pix),
        .reset        (reset_game),
        .hcount       (hcount),
        .hw_vcnt      (hw_vcnt),
        .v_load_pulse (v_load_pulse),
        .p1_rot    (p1_rot),
        .p1_x      (p1_x),
        .p1_y      (p1_y),
        .p2_rot    (p2_rot),
        .p2_x      (p2_x),
        .p2_y      (p2_y),
        .s1_x      (s1_x),
        .s1_y      (s1_y),
        .s1_flight (s1_flight),
        .s1_blast  (s1_blast),
        .s2_x      (s2_x),
        .s2_y      (s2_y),
        .s2_flight (s2_flight),
        .s2_blast  (s2_blast),
        .flash     (flash),
        .rom_addr  (tank_rom_addr),
        .rom_data  (rom_data),
        .p1_video  (tank1_video),
        .p2_video  (tank2_video),
        .s1_video  (shell1_video),
        .s2_video  (shell2_video),
        .b1_video  (blast1_video),
        .b2_video  (blast2_video),
        .p1_window (tank1_window),
        .p2_window (tank2_window),
        .p1_tvr    (tank1_tvr),
        .p2_tvr    (tank2_tvr)
    );

    //=========================================================================
    // PLAYFIELD (maze and score digits from the ROM, 74165 shift register)
    //=========================================================================

    wire playfield_video;
    wire playfield_wall;   // raw ROM pixel, unmasked (also the mine layout)

    playfield u_playfield (
        .clk_pix        (clk_pix),
        .reset          (reset_game),
        .hcount         (hcount),
        .hw_vcnt        (v_hw),
        .de             (de),
        .maze_sel       (maze_sel),
        .rom_addr       (pf_rom_addr),
        .rom_data       (rom_data),
        .video          (playfield_video),
        .wall           (playfield_wall),
        .v_info_out     (v_info)
    );

    //=========================================================================
    // MINEFIELD (see minefield.sv)
    //=========================================================================

    wire mine_video;
    wire minefield_zone;   // 1 = inside the MEH/MEV rectangle (suppresses walls)

    wire f7_clk_out;
    wire h_sync_int = (hcount < 10'd32);   // IC_E13.4 H_SYNC (feeds MEV reset via IC_A11)
    wire mine_hit_any;

    minefield u_minefield (
        .clk_pix  (clk_pix),
        .reset    (reset_game),
        .hcount   (hcount),
        .hw_vcnt  (v_hw),
        .hsync    (h_sync_int),   // internal H_SYNC net (hcount 0..31), not the monitor sync
        .de       (de),
        .field    (playfield_wall),
        .video    (mine_video),
        .zone     (minefield_zone),
        .mine_hit (mine_hit_any),
        .f7_clk_out(f7_clk_out),
        .startq  (startq_wire)
    );

    //=========================================================================
    // PICTURE ELEMENTS
    //
    // Gray background over the whole active line; white walls; black mines;
    // score digits black on the left, white on the right.  See the video
    // mixer at the end for the levels.
    //=========================================================================

    wire is_wall = playfield_video & ~minefield_zone & (hcount >= 10'd160 && hcount < 10'd884);
    wire is_mine = mine_video;

    // An exploding tank flashes inside its own 16 x 16 box:
    //   TANK = WINDO AND (shape XOR (FLASH AND BLO_UP))   (IC_L3 7402, IC_K3)
    wire tank1_pixel = tank1_window & (tank1_video ^ (flash & blo_up1));
    wire tank2_pixel = tank2_window & (tank2_video ^ (flash & blo_up2));

    // Tanks exist only in the maze band (V_INFOQ = 1), not in the score band.
    wire is_tank1 = tank1_pixel & v_info;
    wire is_tank2 = tank2_pixel & v_info;

    // A shell is drawn in flight, its explosion (blast) afterwards; never
    // both at once.
    wire is_s1 = shell1_video;
    wire is_s2 = shell2_video;
    wire is_b1 = blast1_video;
    wire is_b2 = blast2_video;

    //=========================================================================
    // FLASH (IC_A12 7492, divide by 12, clocked once per field)
    //
    // FLASH = pin 8 = QD: high for counts 6-11, a 50 % square wave at
    // 5.07 Hz (60.80 / 12).  (MAME's 7492 model maps pin 8 to QC, the
    // 7490 / 7493 layout; the 7492A datasheet and the schematic put QD on
    // pin 8.)  tank_controls_hw keeps a twin of this counter for TM1, the
    // chip's other output; both count the same frame_pulse.
    //=========================================================================
    reg [3:0] flash_div_cnt;     // mod-12 counter
    wire      flash;
    always @(posedge clk_pix) begin
        if (reset_game)
            flash_div_cnt <= 4'd0;
        else if (frame_pulse) begin
            if (flash_div_cnt == 4'd11)
                flash_div_cnt <= 4'd0;
            else
                flash_div_cnt <= flash_div_cnt + 4'd1;
        end
    end
    assign flash = (flash_div_cnt >= 4'd6);    // QD: counts 6-11

    //=========================================================================
    // BLO_UP1 / BLO_UP2: the explosion one-shots (IC_C11 NE556)
    //
    // Each half is a monostable with TRIGGER and RESET both on the hit
    // signal HT*Q = NOR(HIT*, MTK*), and 1.8M / 1uF timing:
    // Tw = R*C*ln(3) = 1.9775 s (measured on MAME's NE555 model) = 120 fields
    // at 60.797 Hz.  On the board it starts when HT*Q rises (the hit latch
    // clears, about a field after the hit), and a second hit during the
    // pulse would restart it.  Neither difference can occur in play, so a
    // 120-field counter started by the destroyed edge is equivalent.
    //=========================================================================
    localparam [7:0] BLO_UP_FRAMES = 8'd120;
    reg        blo_up1, blo_up2;
    reg [7:0]  blo_up1_cnt, blo_up2_cnt;
    reg        blo_up1_prev, blo_up2_prev;
    reg        t1_destroyed_edge, t2_destroyed_edge;
    reg        cold_start;

    always @(posedge clk_pix) begin
        if (reset_game) begin
            blo_up1      <= 1'b0;
            blo_up2      <= 1'b0;
            blo_up1_cnt  <= 8'd0;
            blo_up2_cnt  <= 8'd0;
            blo_up1_prev <= 1'b0;
            blo_up2_prev <= 1'b0;
            cold_start   <= 1'b1;
        end else begin
            blo_up1_prev <= blo_up1;
            blo_up2_prev <= blo_up2;

            if (start_pulse) begin
                // New game (STARTQ): end any explosion still running, so
                // both tanks start the game alive.  Dropping blo_up* makes
                // p*_revive pulse, which clears the dead latch.
                blo_up1     <= 1'b0;
                blo_up2     <= 1'b0;
                blo_up1_cnt <= 8'd0;
                blo_up2_cnt <= 8'd0;
            end else if (cold_start && frame_pulse) begin
                // Power-on: the HIT / MTK 7474s clock to their inactive
                // state at the first V_RESET, so HT1Q / HT2Q both rise and
                // both one-shots fire once.  The machine boots with ~2 s of
                // both tanks flashing and firing locked out (measured in the
                // full MAME netlist).
                cold_start  <= 1'b0;
                blo_up1     <= 1'b1;
                blo_up1_cnt <= BLO_UP_FRAMES;
                blo_up2     <= 1'b1;
                blo_up2_cnt <= BLO_UP_FRAMES;
            end else begin
                // Tank 1 BLO_UP
                if (t1_destroyed_edge && !blo_up1) begin
                    blo_up1     <= 1'b1;
                    blo_up1_cnt <= BLO_UP_FRAMES;
                end else if (frame_pulse && blo_up1) begin
                    if (blo_up1_cnt == 8'd0)
                        blo_up1 <= 1'b0;
                    else
                        blo_up1_cnt <= blo_up1_cnt - 8'd1;
                end

                // Tank 2 BLO_UP
                if (t2_destroyed_edge && !blo_up2) begin
                    blo_up2     <= 1'b1;
                    blo_up2_cnt <= BLO_UP_FRAMES;
                end else if (frame_pulse && blo_up2) begin
                    if (blo_up2_cnt == 8'd0)
                        blo_up2 <= 1'b0;
                    else
                        blo_up2_cnt <= blo_up2_cnt - 8'd1;
                end
            end
        end
    end

    // When the explosion ends the tank comes back where it was destroyed:
    // BLO_UP has no path to the position counters.  This pulse only clears
    // the dead latch.  The new-game and out-of-bounds returns to the start
    // position are in tank_motion.
    assign p1_revive = blo_up1_prev & ~blo_up1;
    assign p2_revive = blo_up2_prev & ~blo_up2;

    //=========================================================================
    // GAME TIMER AND COINS (IC_H6 555 timer, IC_E6 74107, coin gates
    // IC_B6 / D6 / J6 / N6), measured in nltool on MAME's device models.
    //=========================================================================
    reg attractq_reg;
    reg [13:0] game_timer; // fields left in the game (max 11178)
    reg coin_a_prev, coin_b_prev;
    reg coin_armed;        // IC_E6 74107 toggle: first coin of a 50c game

    // The Board I 25c / 50c switch (OSD Coin Mode) has two poles:
    //   time:   25c puts R53 330k in parallel with R54 680k in the play-time
    //           555 (IC_H6), about 60 s; 50c opens R53, about twice as long.
    //   credit: at 25c every coin starts a game; at 50c the first coin sets
    //           the IC_E6 toggle and the second starts the game, and coins in
    //           both slots at once start it at once (IC_N6).
    // MAME's netlist leaves this switch out (it is wired as 25c).
    //
    // Play time = 109.44 us/ohm x (PLAYTIME pot + 222k at 25c | 680k at 50c),
    // in fields at 60.797 Hz.  GNE ("game near end") covers the last 19.7 %.
    // Option 0 keeps the manual's nominal 60 / 120 s; a real pot set for
    // 60 s (~323k, option 4) gives about 110 s at 50c.
    reg [13:0] game_time_frames;
    reg [13:0] gne_frames;
    always @(*) begin
        case ({game_time_120, play_pot})                       //  pot     seconds
            {1'b0, 3'd0}: begin game_time_frames = 14'd3600;  gne_frames = 14'd710;  end // ideal   60.0
            {1'b0, 3'd1}: begin game_time_frames = 14'd1477;  gne_frames = 14'd291;  end // 0       24.3
            {1'b0, 3'd2}: begin game_time_frames = 14'd2142;  gne_frames = 14'd422;  end // 100k    35.2
            {1'b0, 3'd3}: begin game_time_frames = 14'd2808;  gne_frames = 14'd553;  end // 200k    46.2
            {1'b0, 3'd4}: begin game_time_frames = 14'd3626;  gne_frames = 14'd714;  end // 323k    59.6
            {1'b0, 3'd5}: begin game_time_frames = 14'd4804;  gne_frames = 14'd946;  end // 500k    79.0
            {1'b0, 3'd6}: begin game_time_frames = 14'd6468;  gne_frames = 14'd1274; end // 750k   106.4
            {1'b0, 3'd7}: begin game_time_frames = 14'd8131;  gne_frames = 14'd1602; end // 1M     133.7
            {1'b1, 3'd0}: begin game_time_frames = 14'd7200;  gne_frames = 14'd1420; end // ideal  120.0
            {1'b1, 3'd1}: begin game_time_frames = 14'd4525;  gne_frames = 14'd891;  end // 0       74.4
            {1'b1, 3'd2}: begin game_time_frames = 14'd5190;  gne_frames = 14'd1022; end // 100k    85.4
            {1'b1, 3'd3}: begin game_time_frames = 14'd5855;  gne_frames = 14'd1153; end // 200k    96.3
            {1'b1, 3'd4}: begin game_time_frames = 14'd6674;  gne_frames = 14'd1315; end // 323k   109.8
            {1'b1, 3'd5}: begin game_time_frames = 14'd7852;  gne_frames = 14'd1547; end // 500k   129.1
            {1'b1, 3'd6}: begin game_time_frames = 14'd9515;  gne_frames = 14'd1874; end // 750k   156.5
            default:      begin game_time_frames = 14'd11178; gne_frames = 14'd2202; end // 1M     183.9
        endcase
    end

    // The two MiSTer buttons are the two coin slots: Coin (bit 10) = slot 1,
    // Start (bit 9) = slot 2.  The cabinet has no start button: START is
    // the synchronised coin pulse (IC_D6.1 = NOR(COINQ, credit pole)).
    wire coin_a_edge = joystick_0[10] & ~coin_a_prev;
    wire coin_b_edge = joystick_0[9]  & ~coin_b_prev;

    // A coin starts a game only in attract mode: IC_D6 gate 4 NORs the coin
    // with ATTRACTQ, so a coin during a game does nothing.
    wire credit_ok   = ~game_time_120                    // 25c: every coin
                     | coin_armed                        // 50c: second coin
                     | (coin_a_edge & coin_b_edge);      // both mechs at once
    wire start_pulse = (coin_a_edge | coin_b_edge) & credit_ok & ~attractq_reg;
    wire startq_wire = ~start_pulse;

    // GNE ("game near end"): Q2 / Q3 / Q4 sense the 555's timing capacitor
    // (C25) nearing its threshold, so GNE is on for the last 19.7 % of every
    // game, whatever the pot and coin mode (the capacitor curve has the same
    // shape).  It makes the scores flash.  (MAME's netlist leaves Q2.C and
    // Q3.B unconnected, so GNE never asserts there.)
    wire gne = attractq_reg && (game_timer != 14'd0)
             && (game_timer <= gne_frames);

    always @(posedge clk_pix) begin
        if (reset_game) begin
            attractq_reg <= 1'b0; // start in attract mode
            game_timer   <= 0;
            coin_a_prev  <= 0;
            coin_b_prev  <= 0;
            coin_armed   <= 0;
        end else if (frame_pulse) begin
            coin_a_prev <= joystick_0[10];
            coin_b_prev <= joystick_0[9];

            // IC_E6 toggle: held clear during a game (CLR = ATTRACT), and
            // here also at 25c, where the switch disconnects it (so changing
            // the OSD mode leaves no stale coin).  Toggles once per coin.
            if (attractq_reg || ~game_time_120)
                coin_armed <= 1'b0;
            else if (coin_a_edge ^ coin_b_edge)
                coin_armed <= ~coin_armed;

            if (start_pulse) begin
                // Start a game (START also clears the score counters).
                attractq_reg <= 1'b1;
                game_timer <= game_time_frames;
            end else if (attractq_reg) begin
                if (game_timer > 0) begin
                    game_timer <= game_timer - 1;
                end else begin
                    // Time up (IC_H6.3 -> IC_D6.4 -> IC_E6): back to attract
                    attractq_reg <= 1'b0;
                end
            end
        end
    end

    //=========================================================================
    // COLLISIONS AND SCORING (see tank_collision_hw.sv)
    //=========================================================================
    wire [5:0] p1_score, p2_score;
    wire       mtk1, mtk2;
    assign mine_hit_any = mtk1 | mtk2;

    // Per-tank "destroyed" latches; the rising edge starts BLO_UP and the
    // explosion sound.
    wire t1_dead_lat, t2_dead_lat;
    reg  t1_dead_prev, t2_dead_prev;
    always @(posedge clk_pix) begin
        t1_dead_prev <= t1_dead_lat;
        t2_dead_prev <= t2_dead_lat;
    end
    always @(*) begin
        t1_destroyed_edge = t1_dead_lat & ~t1_dead_prev;
        t2_destroyed_edge = t2_dead_lat & ~t2_dead_prev;
    end

    tank_collision_hw u_tank_collision (
        .clk_pix     (clk_pix),
        .reset       (reset_game),
        .is_tank1    (is_tank1),
        .is_tank2    (is_tank2),
        .is_wall     (is_wall),
        .is_mine     (is_mine),
        .is_s1       (is_s1),
        .is_s2       (is_s2),
        .frame_pulse (frame_pulse),
        .mine_clk    (f7_clk_out),
        .start_pulse (start_pulse),
        .blo_up1     (blo_up1),
        .blo_up2     (blo_up2),
        .p1_revive   (p1_revive),
        .p2_revive   (p2_revive),
        .s1_hit      (s1_hit),
        .s2_hit      (s2_hit),
        .p1_wall_hit (p1_wall_hit),
        .p2_wall_hit (p2_wall_hit),
        .mtk1        (mtk1),
        .mtk2        (mtk2),
        .t1_dead_lat (t1_dead_lat),
        .t2_dead_lat (t2_dead_lat),
        .hit1_lat    (hit1_lat),
        .hit2_lat    (hit2_lat),
        .p1_score    (p1_score),
        .p2_score    (p2_score)
    );

    //=========================================================================
    // SOUND
    //
    // SHOT starts when a shell is fired (FIRE rising).  BOOM starts when a
    // shell explodes (EXPL rising) or a tank is destroyed (also by a mine).
    //=========================================================================
    reg s1_flight_d, s2_flight_d;
    always @(posedge clk_pix) begin
        s1_flight_d <= s1_flight;
        s2_flight_d <= s2_flight;
    end

    wire shot_trig = (s1_flight & ~s1_flight_d) | (s2_flight & ~s2_flight_d);
    wire boom_trig = p1_boom | p2_boom | t1_destroyed_edge | t2_destroyed_edge;

    tank_sound u_tank_sound (
        .clk        (clk_pix),
        .reset      (reset_game),
        .p1_speed   (p1_speed),
        .p2_speed   (p2_speed),
        .shot_trig  (shot_trig),
        .boom_trig  (boom_trig),
        .attract    (~attractq_reg),
        .cab_eq     (cab_eq),
        .putt_trim  (putt_trim),
        .volpot     (volpot_trim),
        .master_vol (master_vol),
        .shot_vol   (shot_vol),
        .boom_vol   (boom_vol),
        .audio_l    (audio_l),
        .audio_r    (audio_r)
    );

    // Score digits, blanked at the FLASH rate while GNE is on: the scores
    // flash near the end of a game (operator manual).  IC_C14
    // NAND(V_INFO, GNE, FLASH) gates PLAYFIELD in IC_A11; the board's V_INFO
    // marks the score band (!v_info here).
    wire is_score = playfield_wall & !v_info & (hcount >= 10'd160 && hcount < 10'd884) & ~(gne & flash);

    //=========================================================================
    // VIDEO MIXER: four TTL outputs summed in a resistor network
    //
    // The four outputs sum into RVID 10k over a VCC pedestal (R7V 680 +
    // R3V 560).  Levels measured in nltool with MAME's gate and 1N914
    // models, in volts:
    //
    //   0.795 V  sync tip (CR1 clamp)
    //   1.39  V  left-half score digit + dark object        (deepest black)
    //   1.892 V  dark sprite: TANK2/MINE/SHELL2/BLAST2 taps  (black)
    //   2.087 V  left-half score digit (F14 560R sink)       (soft black)
    //   2.590 V  ALL TAPS IDLE = background/porch -- also every white+dark
    //            CANCELLATION (dark tank/shell crossing a wall!)   (gray)
    //   2.775 V  white tank over a left-half digit
    //   3.319 V  wall / score digit / white shells / white tank    (white)
    //   4.081 V  white tank over a wall (both white taps)    (super-white)
    //
    // The background is a visible gray: the operator manual sets brightness
    // so the (darker) mines are clearly visible.  It fills the whole active
    // line, so the side margins are gray too.
    //
    // Outputs (the white tank is the core's tank 2, the netlist's TANK1):
    //   B10 (R5V 1k, sources on white-tank pixel)        = is_tank2
    //   H8  (R6V 1k, sources on wall/digit/white shells) = is_wall|is_score|is_s2|is_b2
    //   F14 (R34V 560, SINKS on left-half digit)         = is_score & hcount<452
    //   B7  (R4V 1k, SINKS on dark sprites)              = is_tank1|is_mine|is_s1|is_b1
    //
    // The 8-bit values keep black 0x00, background 0x40 and white 0xE0-0xFF
    // and the measured order of the levels; the exact steps depend on the
    // monitor's brightness and contrast settings.
    //=========================================================================
    wire vid_b10 = is_tank2;
    wire vid_h8  = is_wall | is_score | is_s2 | is_b2;
    wire vid_f14 = is_score & (hcount < 10'd452);
    wire vid_b7  = is_tank1 | is_mine | is_s1 | is_b1;

    reg [7:0] pixel_color;
    always @(*) begin
        if (!de) begin
            pixel_color = 8'h00;                       // blanking
        end else begin
            case ({vid_b10, vid_f14, vid_h8, vid_b7})
                4'b0000: pixel_color = 8'h40;          // 2.590 V background gray
                4'b0001: pixel_color = 8'h00;          // 1.892 V dark sprite
                4'b0010: pixel_color = 8'hE0;          // 3.319 V wall/digit/white shell
                4'b0011: pixel_color = 8'h40;          // 2.590 V dark-over-white CANCELS
                4'b0110: pixel_color = 8'h14;          // 2.087 V left-half digit
                4'b0111: pixel_color = 8'h00;          // 1.39  V left digit + dark
                4'b1000: pixel_color = 8'hE0;          // 3.319 V white tank
                4'b1001: pixel_color = 8'h40;          // 2.590 V white tank + dark CANCELS
                4'b1010: pixel_color = 8'hFF;          // 4.081 V white tank over wall
                4'b1011: pixel_color = 8'hE0;          // 3.319 V tank + wall + dark
                4'b1110: pixel_color = 8'h55;          // 2.775 V white tank + left digit
                4'b1111: pixel_color = 8'h14;          // 2.08  V tank + left digit + dark
                default: pixel_color = 8'h40;          // F14 without H8: unreachable
            endcase
        end
    end

    assign video_r = pixel_color;
    assign video_g = pixel_color;
    assign video_b = pixel_color;

endmodule
