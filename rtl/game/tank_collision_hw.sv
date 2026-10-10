//============================================================================
// tank_collision_hw - collisions, hits and scoring
//
// The board's collision network (nl_tank.cpp gate names), on clk_pix with
// synchronous strobes in place of the board's gated and asynchronous
// latch clocks:
//
//   IC_B7 7408 : PLAYFIELD & SHELL1, PLAYFIELD & SHELL2
//   IC_K8 7400 : NAND(TANK2, SHELL1) -> J8 1PRE, NAND(TANK1, SHELL2) -> J8 2PRE
//   IC_J8 7474 : HIT latches, D = 0, clocked by V_RESET
//   IC_K7 7400 : NAND(TANK1, MINE) -> H7 1PRE, NAND(TANK2, MINE) -> H7 2PRE
//   IC_H7 7474 : MTK (mine) latches, clocked by MEV & V8, cleared by STARTQ
//   IC_B9 7402 : TANK1 & (PLAYFIELD | TANK2); B9.1 = NOR(HT1, B9_13)
//   IC_B8 7402 : TANK2 & (PLAYFIELD | TANK1); B8.1 = NOR(HT2, B8_13)
//   IC_A9 7400 : bounce NAND latches;  IC_A8 7474: BOUNCE, clocked by V_RESET
//   IC_J7 7402 : HT1Q = NOR(HIT1, MTK1), HT2Q = NOR(HIT2, MTK2)
//   IC_C10/D11/E11 7493 : the scores, counting on HT*Q falling.  The
//       schematic shows two separate 6-bit counters; the netlist ties SCR1E
//       and SCR2C to one D11 pin and swaps E11's CP0 / CP1.
//       p1_score counts tank 2's deaths, p2_score tank 1's.
//
// One addition to the board: a kill scores once, and an exploding tank
// bounces off nothing.  The board's HIT and MTK latches re-arm every field
// or mine scan, so a coincidence that lasted would score again each time.
// On a cabinet it does not last (the shell explodes, the mine disappears),
// but the exploding tank is drawn FLASH-inverted for two seconds, and in
// the core's exact timing that inverted shape keeps overlapping the shell
// or mine.  The t*_dead_lat and ~blo_up* gates keep each kill to one point
// and one explosion, as on a cabinet.  (Checked in simulation against a
// gate-level model of the network.)
//============================================================================

module tank_collision_hw (
    input  wire        clk_pix,
    input  wire        reset,

    // Pixel coincidences:
    input  wire        is_tank1,    // TANK1 (in the maze band; inverted by FLASH while exploding)
    input  wire        is_tank2,    // TANK2
    input  wire        is_wall,     // maze wall (PLAYFIELD, none in the minefield)
    input  wire        is_mine,     // MINE
    input  wire        is_s1,       // SHELL1
    input  wire        is_s2,       // SHELL2

    // Strobes and state:
    input  wire        frame_pulse, // V_RESET: clears HIT (J8) and BOUNCE (A8), scores
    input  wire        mine_clk,    // MEV & V8: clears MTK (H7)
    input  wire        start_pulse, // new game: clear scores and state
    input  wire        blo_up1,     // tank 1 exploding
    input  wire        blo_up2,
    input  wire        p1_revive,   // tank 1's explosion ended: clear its dead latch
    input  wire        p2_revive,

    // Outputs:
    output reg         s1_hit,      // shell 1 hit a wall or tank 2 (B9.4): explode
    output reg         s2_hit,      // shell 2 likewise (B8.4)
    output wire        p1_wall_hit, // BOUNCE1 (A8.5) -> tank_controls / tank_motion
    output wire        p2_wall_hit, // BOUNCE2 (A8.9)
    output reg         mtk1,        // MTK1 (H7.5): mine killed tank1
    output reg         mtk2,        // MTK2 (H7.9): mine killed tank2
    output reg         t1_dead_lat, // tank 1 destroyed (starts BLO_UP1)
    output reg         t2_dead_lat, // tank 2 destroyed (starts BLO_UP2)
    output reg         hit1_lat,    // IC_J8 HIT1 this field: shell 2 hit tank 1
    output reg         hit2_lat,    // IC_J8 HIT2 this field: shell 1 hit tank 2
    output reg  [5:0]  p1_score,    // tank 1's score (tank 2 deaths)
    output reg  [5:0]  p2_score     // tank 2's score (tank 1 deaths)
);

    //------------------------------------------------------------------------
    // Coincidences (the IC_B7 / B8 / B9 / K7 / K8 gate inputs)
    //------------------------------------------------------------------------
    // Shell on tank (K8 -> J8 HIT):
    wire hit2_coin = is_s1 & is_tank2;        // TANK2 & SHELL1 (P1 scores)
    wire hit1_coin = is_s2 & is_tank1;        // TANK1 & SHELL2 (P2 scores)
    // Tank on mine (K7 -> H7 MTK):
    wire mtk1_coin = is_tank1 & is_mine;      // TANK1 & MINE
    wire mtk2_coin = is_tank2 & is_mine;      // TANK2 & MINE
    // Bounce: tank on a wall or the other tank (B9_13 / B8_13), or hit by a
    // shell (B*.1 = NOR(HT*, B*_13)).
    wire bounce1_coin = is_tank1 & (is_wall | is_tank2 | is_s2);  // B9_13 + HT1-from-shell
    wire bounce2_coin = is_tank2 & (is_wall | is_tank1 | is_s1);  // B8_13 + HT2-from-shell

    //------------------------------------------------------------------------
    // BOUNCE (IC_A9 latch, sampled at V_RESET by IC_A8): set by the
    // coincidence, cleared at frame_pulse.  Not while the tank is exploding
    // (see the header).
    //------------------------------------------------------------------------
    reg p1_hit_reg, p2_hit_reg;
    assign p1_wall_hit = p1_hit_reg;
    assign p2_wall_hit = p2_hit_reg;

    //------------------------------------------------------------------------
    // Scoring: the 7493s count each time HIT* or MTK* goes high.  Here a
    // "scored this field" flag (once per kill) adds 1 at frame_pulse.
    //------------------------------------------------------------------------
    reg p1_scores_this_frame, p2_scores_this_frame;

    // Mine-scan clock edge: clears the H7 MTK latches.
    reg mine_clk_d;

    always @(posedge clk_pix) begin
        if (reset) begin
            s1_hit <= 0; s2_hit <= 0;
            p1_hit_reg <= 0; p2_hit_reg <= 0;
            t1_dead_lat <= 0; t2_dead_lat <= 0;
            hit1_lat <= 0; hit2_lat <= 0;
            p1_scores_this_frame <= 0; p2_scores_this_frame <= 0;
            p1_score <= 0; p2_score <= 0;
            mtk1 <= 0; mtk2 <= 0;
            mine_clk_d <= 0;
        end else if (start_pulse) begin
            // New game (STARTQ): clear the scores (7493 R0) and all state,
            // so a tank still exploding at the end of a game starts alive.
            p1_score <= 0; p2_score <= 0;
            mtk1 <= 0; mtk2 <= 0;
            t1_dead_lat <= 0; t2_dead_lat <= 0;
            hit1_lat <= 0; hit2_lat <= 0;
            s1_hit <= 0; s2_hit <= 0;
            p1_hit_reg <= 0; p2_hit_reg <= 0;
            p1_scores_this_frame <= 0; p2_scores_this_frame <= 0;
        end else begin
            //----------------------------------------------------------------
            // IC_H7 MTK latch: cleared on the mine-scan clock, set by the
            // K7 coincidence, once per kill (~t*_dead_lat).
            //----------------------------------------------------------------
            mine_clk_d <= mine_clk;
            if (mine_clk && !mine_clk_d) begin
                mtk1 <= 0;
                mtk2 <= 0;
            end else begin
                if (mtk1_coin && !t1_dead_lat) mtk1 <= 1;
                if (mtk2_coin && !t2_dead_lat) mtk2 <= 1;
            end

            // Dead latch cleared when the explosion ends (p*_revive comes
            // one clock after frame_pulse, so it is outside that branch).
            if (p1_revive) t1_dead_lat <= 0;
            if (p2_revive) t2_dead_lat <= 0;

            if (frame_pulse) begin
                // V_RESET: clear HIT, BOUNCE and the shell hits; add scores.
                s1_hit <= 0;
                s2_hit <= 0;
                p1_hit_reg <= 0;
                p2_hit_reg <= 0;
                hit1_lat <= 0;
                hit2_lat <= 0;

                if (p1_scores_this_frame) p1_score <= p1_score + 1'b1;
                if (p2_scores_this_frame) p2_score <= p2_score + 1'b1;

                p1_scores_this_frame <= 0;
                p2_scores_this_frame <= 0;
            end else begin
                //------------------------------------------------------------
                // A shell explodes on a wall or on the live other tank
                // (B9.4 = NOR(HIT2, PLAYFIELD & SHELL1); B8.4 likewise).  B9.4
                // has no mine input, so shells fly over mines.  An exploding
                // tank does not stop shells.
                //------------------------------------------------------------
                if (is_s1 && (is_wall | (is_tank2 & ~t2_dead_lat))) s1_hit <= 1;
                if (is_s2 && (is_wall | (is_tank1 & ~t1_dead_lat))) s2_hit <= 1;

                // Bounce (not while exploding)
                if (bounce1_coin && !blo_up1) p1_hit_reg <= 1;
                if (bounce2_coin && !blo_up2) p2_hit_reg <= 1;

                // Tank destroyed: by a shell (HIT) or a mine (MTK), once.
                if ((hit1_coin | mtk1_coin) && !t1_dead_lat) t1_dead_lat <= 1;
                if ((hit2_coin | mtk2_coin) && !t2_dead_lat) t2_dead_lat <= 1;

                // HIT latches for the turn kick in tank_controls_hw (shell
                // hits only; MTK has no path to IC_H11), once per kill.
                if (hit1_coin && !t1_dead_lat) hit1_lat <= 1;
                if (hit2_coin && !t2_dead_lat) hit2_lat <= 1;

                // Score, once per kill.
                if ((hit2_coin | mtk2_coin) && !t2_dead_lat) p1_scores_this_frame <= 1;
                if ((hit1_coin | mtk1_coin) && !t1_dead_lat) p2_scores_this_frame <= 1;
            end
        end
    end
endmodule
