//============================================================================
// Tank (Kee Games / Atari, 1974) - shell flight and explosion timers
//============================================================================
//
// Each shell has a dual DM9602 one-shot: FIRE (the flight) and EXPL (the
// explosion that follows).  Pulse widths use the DM9602 datasheet equation
//   Tw = 0.32 * R * C * (1 + 0.7 / R[kOhm])
// (MAME's 9602 model uses the 74123's constant instead, which gives
// different widths.)
//
// IC_C9, the white tank's shell (netlist SHELL1):
//   FIRE: the FIRE1_ADJUST 50k pot and C11 47 uF.  Factory (mid) 386.5 ms,
//     range 10.5 .. 762.5 ms.  Triggered when IC_C9.11 (A2) falls; the
//     button reaches A2 through the IC_B15 NAND latch, armed by IC_A15
//     (see FIRE ARM below).  A hit clears it early (CLR from IC_B9).
//   EXPL: 47k and C12 22 uF = 335.8 ms, started as FIRE ends.
// IC_C8, the black tank's shell: FIRE R16 33k / C8 100 uF = 1.0784 s
//   (fixed); EXPL 47k / 22 uF = 335.8 ms.
//
// States per shell:
//   IDLE   - waiting to fire.
//   FLIGHT - FIRE active: the shell is drawn and steps once per field; a hit
//            (s*_hit) ends the flight early.
//   BLAST  - EXPL active: the explosion is drawn where the shell stopped.
// p*_boom pulses as a flight ends (EXPL rising, AC-coupled to the BOOM
// sound); s*_fire_edge pulses as a shell is fired.
//============================================================================

module tank_shells (
    input  wire        clk_pix,
    input  wire        reset,
    input  wire        frame_pulse,

    // FIRE1_ADJUST pot position (OSD Operator Adjust; 0 = factory).  The
    // operator manual: firing range adjustable "for white tank only", the
    // black tank's pre-set.  The netlist's SHELL1 (IC_C9) is the white tank,
    // which is the core's tank 2, so the pot sets core shell 2 and core
    // shell 1 (black) gets the fixed 1.0784 s.
    input  wire [2:0]  fire1_range,

    // FIRE-ARM inputs (IC_A15 / IC_B15)
    input  wire        attractq,       // IC_A15 D (no arming in attract)
    input  wire        hmce_tick,      // HMCEQ rising: once per field (A15 clock)
    input  wire        blo_up1,        // tank 1 exploding -> clears shell 2's arm
    input  wire        blo_up2,        // tank 2 exploding -> clears shell 1's arm
    input  wire        tvr1,           // tank 1 TVR (SRS for shell 1 while idle)
    input  wire        tvr2,           // tank 2 TVR (SRS for shell 2 while idle)

    // Tank 1
    input  wire        p1_fire,        // fire BUTTON (level)
    input  wire        s1_hit,
    output wire        s1_flight,
    output wire        s1_blast,
    output wire        p1_boom,
    output wire        s1_fire_edge,
    output wire        s1_hmce,

    // Tank 2
    input  wire        p2_fire,        // fire BUTTON (level)
    input  wire        s2_hit,
    output wire        s2_flight,
    output wire        s2_blast,
    output wire        p2_boom,
    output wire        s2_fire_edge,
    output wire        s2_hmce
);

    //=========================================================================
    // One-shot widths in 14.318181 MHz clocks (25 bits hold the largest):
    //   386.528 ms = 5_534_378   (FIRE1_ADJUST at mid, factory)
    //   1.0784 s   = 15_440_726  (fixed FIRE, IC_C8)
    //   335.808 ms = 4_808_160   (EXPL)
    //=========================================================================
    localparam [24:0] FIRE1_DUR = 25'd5_534_378;
    localparam [24:0] FIRE2_DUR = 25'd15_440_726;
    localparam [24:0] EXPL_DUR  = 25'd4_808_160;

    // FIRE1_ADJUST positions (the white tank, core shell 2).  With C11 =
    // 47 uF the equation is Tw = 15.04 us x (R[ohm] + 700): 10.5 ms at 0 to
    // 762.5 ms at 50k.
    reg [24:0] white_dur;
    always @(*) begin
        case (fire1_range)
            3'd1:    white_dur = 25'd150_742;     //  0 k     10.5 ms (Min)
            3'd2:    white_dur = 25'd2_842_560;   // 12.5k   198.5 ms (Short)
            3'd3:    white_dur = 25'd8_226_196;   // 37.5k   574.5 ms (Long)
            3'd4:    white_dur = 25'd10_918_014;  // 50 k    762.5 ms (Max)
            default: white_dur = FIRE1_DUR;       // 25 k    386.5 ms (Mid, factory)
        endcase
    end

    localparam [1:0] IDLE   = 2'd0;
    localparam [1:0] FLIGHT = 2'd1;
    localparam [1:0] BLAST  = 2'd2;

    //=========================================================================
    // FIRE ARM - IC_A15 7474 + IC_B15 NAND latch (per shell)
    //
    //   A15:  set (D = ATTRACTQ) at each HMCEQ rise, once a field; cleared
    //         by NOR(BLO_UP of the other tank, SRS), where SRS is the tank's
    //         own TVR while its shell is idle (FPE = NAND(FIREQ, EXPLQ),
    //         IC_C1).
    //   B15:  not armed -> out = 1; armed and pressed -> out = 0; else hold.
    //   9602: FIRE starts when out falls.
    //
    // A press fires at once if armed, else at the next HMCE.  A held button
    // fires again as soon as the shell and its explosion are over, and as
    // soon as an opponent's explosion ends.  (A fall while the shell is
    // still busy would retrigger the 9602 on the board; it cannot happen in
    // play and is ignored here.)
    //=========================================================================
    reg s1_armed, s1_b15, s2_armed, s2_b15;
    wire s1_idle = (s1_state == IDLE);
    wire s2_idle = (s2_state == IDLE);
    wire s1_arm_clr = blo_up2 | (s1_idle & tvr1);
    wire s2_arm_clr = blo_up1 | (s2_idle & tvr2);
    wire s1_trig = s1_b15 & s1_armed & p1_fire;   // B15 output falls
    wire s2_trig = s2_b15 & s2_armed & p2_fire;

    always @(posedge clk_pix) begin
        if (reset) begin
            s1_armed <= 1'b0;  s1_b15 <= 1'b1;
            s2_armed <= 1'b0;  s2_b15 <= 1'b1;
        end else begin
            if (s1_arm_clr)     s1_armed <= 1'b0;
            else if (hmce_tick) s1_armed <= attractq;
            if (s2_arm_clr)     s2_armed <= 1'b0;
            else if (hmce_tick) s2_armed <= attractq;
            s1_b15 <= ~s1_armed | (s1_b15 & ~p1_fire);
            s2_b15 <= ~s2_armed | (s2_b15 & ~p2_fire);
        end
    end

    reg [1:0]  s1_state;
    reg [24:0] s1_cnt;
    reg        s1_fire_edge_reg;
    reg        s1_boom_reg;

    reg [1:0]  s2_state;
    reg [24:0] s2_cnt;
    reg        s2_fire_edge_reg;
    reg        s2_boom_reg;

    always @(posedge clk_pix) begin
        if (reset) begin
            s1_state         <= IDLE;
            s1_cnt           <= 25'd0;
            s1_fire_edge_reg <= 1'b0;
            s1_boom_reg      <= 1'b0;
            s2_state         <= IDLE;
            s2_cnt           <= 25'd0;
            s2_fire_edge_reg <= 1'b0;
            s2_boom_reg      <= 1'b0;
        end else begin
            s1_fire_edge_reg <= 1'b0;
            s2_fire_edge_reg <= 1'b0;
            s1_boom_reg      <= 1'b0;
            s2_boom_reg      <= 1'b0;

            //-----------------------------------------------------------------
            // Shell 1
            //-----------------------------------------------------------------
            case (s1_state)
                IDLE: begin
                    if (s1_trig) begin
                        s1_state         <= FLIGHT;
                        // tank 1 (black): the fixed range (IC_C8, 1.0784 s)
                        s1_cnt           <= FIRE2_DUR;
                        s1_fire_edge_reg <= 1'b1;
                    end
                end
                FLIGHT: begin
                    if (s1_hit || s1_cnt == 25'd0) begin
                        s1_state    <= BLAST;
                        s1_cnt      <= EXPL_DUR;
                        s1_boom_reg <= 1'b1;        // EXPL starts
                    end else begin
                        s1_cnt <= s1_cnt - 25'd1;
                    end
                end
                BLAST: begin
                    if (s1_cnt == 25'd0)
                        s1_state <= IDLE;
                    else
                        s1_cnt <= s1_cnt - 25'd1;
                end
                default: s1_state <= IDLE;
            endcase

            //-----------------------------------------------------------------
            // Shell 2
            //-----------------------------------------------------------------
            case (s2_state)
                IDLE: begin
                    if (s2_trig) begin
                        s2_state         <= FLIGHT;
                        // tank 2 (white): the FIRE1_ADJUST pot (IC_C9)
                        s2_cnt           <= white_dur;
                        s2_fire_edge_reg <= 1'b1;
                    end
                end
                FLIGHT: begin
                    if (s2_hit || s2_cnt == 25'd0) begin
                        s2_state    <= BLAST;
                        s2_cnt      <= EXPL_DUR;
                        s2_boom_reg <= 1'b1;
                    end else begin
                        s2_cnt <= s2_cnt - 25'd1;
                    end
                end
                BLAST: begin
                    if (s2_cnt == 25'd0)
                        s2_state <= IDLE;
                    else
                        s2_cnt <= s2_cnt - 25'd1;
                end
                default: s2_state <= IDLE;
            endcase
        end
    end

    assign s1_flight    = (s1_state == FLIGHT);
    assign s2_flight    = (s2_state == FLIGHT);
    assign s1_blast     = (s1_state == BLAST);
    assign s2_blast     = (s2_state == BLAST);
    assign p1_boom      = s1_boom_reg;
    assign p2_boom      = s2_boom_reg;
    assign s1_fire_edge = s1_fire_edge_reg;
    assign s2_fire_edge = s2_fire_edge_reg;

    // HMCE: a step per field in flight only.  During the explosion the
    // shell stays put (on the board EXPL1 makes IC_J3.12 load zero motion
    // into the velocity latches).
    assign s1_hmce      = s1_flight;
    assign s2_hmce      = s2_flight;

endmodule
