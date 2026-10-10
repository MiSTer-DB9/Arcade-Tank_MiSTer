//============================================================================
// tank_controls_hw - the tread levers, rotation and speed counters
//
// The board's control chain per tank: lever decode (IC_E15 / D15 NOR
// gates), rotation counter (74193 + 74107), speed counter (7493) and step
// divider (9316), with the gate equations of nl_tank.cpp.  On the board
// these counters have gated and ripple clocks; here every flop runs on
// clk_pix with clock enables and synchronous loads, which synthesises
// reliably and gives the same counts.
//
// Behaviour that follows from the circuit:
//   - A bounce clears the speed: IC_F14.6 = NAND(NAND(STOP,TM1), ATTRACTQ,
//     BOUNCE1Q) drives the 7493 R0, so a tank that hits a wall stops.
//   - Braking acts on the TM1 tick, like acceleration, not every field.
//   - The step divider is cleared only while the speed is 0
//     (IC_H14 ~CLR = OR(SP0, SP1, SP2)).
//   - TM1 ticks once every 6 fields (98.5 ms): a full turn of 32 steps
//     takes 3.15 s, and full speed is reached in about 0.6 s.
//   - Turn kick: each time a player's shell hits the other tank, the
//     SHOOTER's tank turns one step right.  IC_H11.6 = AND(NAND(TM1,RR1),
//     HIT2Q) clocks the 74193 up; the J8 HIT latch is cleared at V_RESET,
//     before TM1 can pulse, so its rising edge is itself one count.
//============================================================================

module tank_controls_hw (
    input  wire        clk_pix,
    input  wire        reset,

    input  wire [31:0] joystick_0,
    input  wire [31:0] joystick_1,

    input  wire        frame_pulse,    // once per field (VLD1 / VLD2)
    input  wire        attractq,       // attract mode (active low)
    input  wire        startq,         // start mode (active low)

    input  wire        p1_wall_hit,
    input  wire        p2_wall_hit,

    input  wire        hit1_lat,       // IC_J8 HIT1: shell 2 hit tank 1 -> tank 2 kick
    input  wire        hit2_lat,       // IC_J8 HIT2: shell 1 hit tank 2 -> tank 1 kick

    output wire [4:0]  p1_rot,
    output wire        p1_acc,
    output wire        p1_stop,
    output wire [2:0]  p1_speed,
    output wire        p1_g01,
    output wire        p1_fire,

    output wire [4:0]  p2_rot,
    output wire        p2_acc,
    output wire        p2_stop,
    output wire [2:0]  p2_speed,
    output wire        p2_g01,
    output wire        p2_fire,

    output wire        p1_bounce,
    output wire        p2_bounce
);

    //=========================================================================
    // Lever decode (IC_E15 / D15 7402).  Every command needs both levers;
    // one lever alone does nothing:
    //   ACC  = L fwd & R fwd        STOP = L back & R back
    //   RR   = L fwd & R back       RL   = L back & R fwd
    // The d-pad is a one-hand shortcut with no cabinet counterpart
    // (up = ACC, down = STOP, right = RR, left = RL).
    //=========================================================================
    wire p1_dpad_up    = joystick_0[3];
    wire p1_dpad_down  = joystick_0[2];
    wire p1_dpad_left  = joystick_0[1];
    wire p1_dpad_right = joystick_0[0];
    wire p1_rt_fwd = joystick_0[4];
    wire p1_rt_rev = joystick_0[5];
    wire p1_lt_fwd = joystick_0[6];
    wire p1_lt_rev = joystick_0[7];
    wire acc1  = (p1_lt_fwd & p1_rt_fwd) | (p1_dpad_up   & ~p1_dpad_down);
    wire stop1 = (p1_lt_rev & p1_rt_rev) | (p1_dpad_down & ~p1_dpad_up);
    wire turn_right_1 = (p1_lt_fwd & p1_rt_rev) | p1_dpad_right;
    wire turn_left_1  = (p1_lt_rev & p1_rt_fwd) | p1_dpad_left;

    wire p2_dpad_up    = joystick_1[3];
    wire p2_dpad_down  = joystick_1[2];
    wire p2_dpad_left  = joystick_1[1];
    wire p2_dpad_right = joystick_1[0];
    wire p2_rt_fwd = joystick_1[4];
    wire p2_rt_rev = joystick_1[5];
    wire p2_lt_fwd = joystick_1[6];
    wire p2_lt_rev = joystick_1[7];
    wire acc2  = (p2_lt_fwd & p2_rt_fwd) | (p2_dpad_up   & ~p2_dpad_down);
    wire stop2 = (p2_lt_rev & p2_rt_rev) | (p2_dpad_down & ~p2_dpad_up);
    wire turn_right_2 = (p2_lt_fwd & p2_rt_rev) | p2_dpad_right;
    wire turn_left_2  = (p2_lt_rev & p2_rt_fwd) | p2_dpad_left;

    assign p1_acc = acc1; assign p1_stop = stop1;
    assign p2_acc = acc2; assign p2_stop = stop2;
    assign p1_fire = joystick_0[8] & attractq;
    assign p2_fire = joystick_1[8] & attractq;

    //=========================================================================
    // TM1 = IC_A13.1 = NOR(ATTRACT, NAND(A12.QA, A12.QB, VLD2)): one pulse
    // every six fields (98.5 ms).
    //
    // IC_A12 is a 7492 (divide by 12, clocked once per field, never reset).
    // QA & QB is true only at counts 3 and 9, so the VLD2 strobe passes once
    // every 6 fields.  Here TM1 is a one-field count enable.  (MAME's 7492
    // model swaps QB and QD on the pins, which makes its TM1 come in bursts
    // of three; the 7492A datasheet and the schematic's pin labels give the
    // even 1-in-6.)
    //
    // ATTRACT holds TM1 low, so tanks neither turn nor speed up in attract
    // mode; the 7492 itself keeps counting.  tank_core keeps a twin of this
    // counter for FLASH (QD, the chip's other output).
    //=========================================================================
    reg [3:0] a12_cnt;          // IC_A12 7492 /12 state, free-running
    reg       tm1;
    wire [3:0] a12_next = (a12_cnt == 4'd11) ? 4'd0 : a12_cnt + 4'd1;
    always @(posedge clk_pix) begin
        if (reset) begin
            a12_cnt <= 4'd0;
            tm1     <= 1'b0;
        end else if (frame_pulse) begin
            a12_cnt <= a12_next;
            // high for the one field in which the count reads 3 or 9 (the
            // field whose VLD2 strobe the real B12 NAND lets through)
            tm1     <= attractq & ((a12_next == 4'd3) | (a12_next == 4'd9));
        end
    end

    // Turn kick: each tank's turn-right path takes the OTHER tank's HIT
    // latch (tank 1 <- HIT2, tank 2 <- HIT1), see the header.
    //
    // Start heading: the rotation MSB is the IC_D8 74107, and the two tanks
    // take opposite outputs of it (1D4 = pin 2, Q-bar; 2D4 = pin 5, Q).
    // STARTQ clears it and loads the 74193s with 8, so the white tank
    // (right, core tank 2) starts at 24, facing left, and the black tank
    // (left, core tank 1) at 8, facing right: they start facing each other.

    tank_ctrl_chain_hw #(.START_ROT(5'd8)) u_p1 (
        .clk_pix (clk_pix), .reset (reset), .frame_pulse (frame_pulse), .tm1 (tm1),
        .acc (acc1), .stop (stop1), .turn_r (turn_right_1), .turn_l (turn_left_1),
        .attractq (attractq), .startq (startq),
        .wall_hit (p1_wall_hit), .hit_opp (hit2_lat),
        .rot (p1_rot), .speed (p1_speed), .g01 (p1_g01), .bounce (p1_bounce)
    );

    tank_ctrl_chain_hw #(.START_ROT(5'd24)) u_p2 (
        .clk_pix (clk_pix), .reset (reset), .frame_pulse (frame_pulse), .tm1 (tm1),
        .acc (acc2), .stop (stop2), .turn_r (turn_right_2), .turn_l (turn_left_2),
        .attractq (attractq), .startq (startq),
        .wall_hit (p2_wall_hit), .hit_opp (hit1_lat),
        .rot (p2_rot), .speed (p2_speed), .g01 (p2_g01), .bounce (p2_bounce)
    );

endmodule


//============================================================================
// tank_ctrl_chain_hw - one tank's rotation, speed and step divider, on
// clk_pix with frame_pulse / tm1 enables (gate names from nl_tank.cpp).
//============================================================================
module tank_ctrl_chain_hw #(
    // Heading loaded by STARTQ: {D8 output, 74193 load 8}: 8 for the black
    // tank, 24 for the white tank.
    parameter [4:0] START_ROT = 5'd8
) (
    input  wire        clk_pix,
    input  wire        reset,
    input  wire        frame_pulse,    // once per field: VLD (divider) and V_RESET (bounce)
    input  wire        tm1,            // TM1 turn / speed tick (count enable)

    input  wire        acc,            // ACC1
    input  wire        stop,           // STOP1
    input  wire        turn_r,         // RR1
    input  wire        turn_l,         // RL1
    input  wire        attractq,       // ATTRACTQ (active low)
    input  wire        startq,         // STARTQ   (active low)
    input  wire        wall_hit,       // collision -> BOUNCE1
    input  wire        hit_opp,        // the other tank's J8 HIT latch, this field

    output reg  [4:0]  rot,            // {P*D4 (74107), P*D3..P*D0 (74193)}
    output reg  [2:0]  speed,          // {SP2,SP1,SP0} = 7493 QD,QC,QB
    output wire        g01,            // IC_L13.6
    output reg         bounce          // BOUNCE1 (IC_A8, active high)
);

    reg [3:0] div;                                  // IC_H14 9316 state

    wire speed_zero = (speed == 3'd0);

    // IC_H14 RC: terminal count, but the 9316 is held CLEARed (~CLR =
    // OR(SP0,SP1,SP2)) while speed==0, so RC can only assert when speed!=0.
    wire rc = ~speed_zero & (div == 4'd15);

    // IC_L13.6  G01 = NAND(~RC, BOUNCE1Q) = RC | ~BOUNCE1Q.
    assign g01 = rc | bounce;

    // IC_F14.6 speed-counter R0 = NAND(NAND(STOP,TM1), ATTRACTQ, BOUNCE1Q)
    //          -> reset when (STOP & TM1) | ~ATTRACTQ | BOUNCE(=~BOUNCE1Q).
    wire spd_reset = (stop & tm1) | ~attractq | bounce;

    // IC_L13.8 / cap: NAND(SP1,SP2)==0 at speed 6 freezes CKB -> cap = 6.
    wire capped = speed[1] & speed[2];

    // Turn kick (IC_H11.6 = AND(NAND(TM1,RR1), HIT2Q) -> 74193 count up):
    // +1 at frame_pulse when the other tank's HIT latch was set during the
    // field, on top of the normal TM1 count.

    always @(posedge clk_pix) begin
        if (reset) begin
            rot    <= START_ROT;        // 74193 load 8 + 74107 cleared
            speed  <= 3'd0;
            div    <= 4'd0;
            bounce <= 1'b0;
        end else if (frame_pulse) begin
            // IC_A8 7474: BOUNCE1 latched from the collision each V_RESET.
            bounce <= wall_hit;

            if (~startq) begin
                // STARTQ: 74193 loads 8, the 74107 clears; the MSB depends
                // on which D8 output this tank uses.
                rot   <= START_ROT;
                speed <= 3'd0;
            end else begin
                // Rotation 74193 (low 4 bits) + 74107 (MSB): +/-1 per TM1
                // tick, plus the hit kick (kick + turn left = no change).
                if (tm1 && turn_r)       rot <= rot + (hit_opp ? 5'd2 : 5'd1);
                else if (tm1 && turn_l)  rot <= rot - (hit_opp ? 5'd0 : 5'd1);
                else if (hit_opp)        rot <= rot + 5'd1;

                // Speed 7493: R0 clear wins; else +1 per TM1 while ACC,
                // stopping at 6 (NAND(SP1, SP2)).
                if (spd_reset)                    speed <= 3'd0;
                else if (tm1 && acc && ~capped)   speed <= speed + 3'd1;
            end

            // Divider 9316: cleared at speed 0; reloads speed*2 at RC or a
            // bounce; else counts.  A step every 16 - 2*speed fields.
            if (speed_zero)  div <= 4'd0;
            else if (g01)    div <= {speed, 1'b0};
            else             div <= div + 4'd1;
        end
    end

endmodule
