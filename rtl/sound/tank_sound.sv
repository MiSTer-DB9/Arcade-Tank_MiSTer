//============================================================================
// Tank (Kee Games / Atari, 1974) - sound
//============================================================================
//
// The board's sound is analog: no sound chip.  This module models each
// circuit from the schematic, with the constants measured in MAME's
// netlist simulator (nltool) on its NE555 / NE566 / MC3340 / UA741 device
// models.  (MAME's Tank driver has no sound: its netlist ties the engines
// to ground and leaves the engine block commented out, with pin errors in
// the MC3340 part; that block, corrected, is what was measured.)
//
//   MOTOR1/2 - engine (tank_motor below): an NE555 "putt" oscillator into
//              an MC3340 voltage-controlled attenuator whose gain an NE566
//              triangle oscillator sweeps (the engine tone).  Both rise with
//              the 3-bit speed.
//   SHOT     - noise through the MC3340 IC_K6, opened by a 9602 one-shot
//              when a shell is fired.
//   BOOM     - noise through the MC3340 IC_L6, opened by a 9602 one-shot
//              when a shell explodes or a tank is destroyed.
//   Mixer    - OUT1 = MOTOR1 + SHOT + BOOM, OUT2 = MOTOR2 + SHOT + BOOM
//              (equal 33k resistors R102-108MX): each tank's engine on its
//              own speaker, shot and explosion on both.
//
// Both 9602s use 100k / 0.1 uF: Tw = 0.32 x R x C x (1 + 0.7/R[k]) =
// 3.22 ms (datasheet).  That only opens the voice; the sound is the RC
// recovery afterwards (see tank_voice).
//============================================================================

module tank_sound (
    input  wire        clk,        // 14.318181 MHz system clock
    input  wire        reset,

    input  wire [2:0]  p1_speed,   // tank 1 speed counter (0..6)
    input  wire [2:0]  p2_speed,   // tank 2 speed counter (0..6)
    input  wire        shot_trig,  // 1-cycle pulse: a shell was launched
    input  wire        boom_trig,  // 1-cycle pulse: a shell exploded or a tank was destroyed
    input  wire        attract,    // 1 = attract mode: engines muted (Q30, IC_N13)
    input  wire        cab_eq,     // 1 = engine through the cabinet-speaker model

    // Engine trimmers (OSD Operator Adjust).  The board has a pair per
    // engine (MOTOR1_VOL / VOL2, MOTOR2_VOL / VOL2); one setting drives both.
    input  wire [2:0]  putt_trim,  // MOTOR*_VOL2 putt rate (0 = factory, ~10k)
    input  wire [1:0]  volpot,     // MOTOR*_VOL volume (0 = loud end, 24 dB)

    input  wire [2:0]  master_vol, // OSD volume fields: 0 = Max .. 7 = Mute
    input  wire [2:0]  shot_vol,
    input  wire [2:0]  boom_vol,

    output wire [15:0] audio_l,    // signed 16-bit
    output wire [15:0] audio_r
);

    // 9602 width, 3.22 ms = 180 ticks of ce_aud (55.93 kHz)
    localparam        [8:0]  SHOT_DUR   = 9'd180;
    localparam        [8:0]  BOOM_DUR   = 9'd180;    // same R and C as SHOT
    //-------------------------------------------------------------------------

    //=========================================================================
    // Audio-rate clock enable  (~56 kHz = 14.318 MHz / 256)
    //=========================================================================
    reg [7:0] ce_div;
    always @(posedge clk) ce_div <= reset ? 8'd0 : ce_div + 8'd1;
    wire ce_aud = (ce_div == 8'd0);

    //=========================================================================
    // Noise: a 17-bit LFSR through a one-pole ~4 kHz low-pass.
    // On the board (Board I sheet 2) a selected 2N3643 junction in avalanche
    // feeds a UA741 with a gain of about 5000, so the op-amp clips, and its
    // bandwidth and the C43 220 pF input pole limit the band.  Measured at
    // the NOISE node: flat from 25 Hz to ~2 kHz, then about -6 dB/octave.
    // The filtered LFSR matches that within ~3 dB.
    //=========================================================================
    // 8 LFSR steps per sample, so consecutive samples are independent
    function [16:0] lfsr8(input [16:0] s);
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) s = {s[15:0], s[16] ^ s[13]};
            lfsr8 = s;
        end
    endfunction

    reg  [16:0] lfsr;
    reg  signed [10:0] noise_lp;
    // the x93 product needs 19 bits
    wire signed [18:0] nz_x    = $signed({11'd0, lfsr[7:0]}) - 19'sd128;
    wire signed [18:0] nz_step = ((nz_x - noise_lp) * 19'sd93) >>> 8;
    always @(posedge clk) begin
        if (reset) begin
            lfsr     <= 17'h0CAFE;           // any non-zero seed
            noise_lp <= 11'sd0;
        end else if (ce_aud) begin
            lfsr     <= lfsr8(lfsr);
            noise_lp <= noise_lp + nz_step[10:0];
        end
    end
    wire signed [9:0] noise = noise_lp[9:0];   // band-limited, ~+/-100

    //=========================================================================
    // SHOT / BOOM one-shots (retriggerable).  The 3.22 ms pulse only pulls
    // the MC3340 control pin down to a diode level (CR19; CR21 + CR22); the
    // sound you hear is the RC recovery after it: R64A x C28A = 0.18 s for
    // the shot, R72A x C41A = 0.93 s for the explosion (see tank_voice).
    //=========================================================================
    reg [8:0] shot_cnt;
    reg [8:0] boom_cnt;
    always @(posedge clk) begin
        if (reset) begin
            shot_cnt <= 9'd0;
            boom_cnt <= 9'd0;
        end else begin
            if (shot_trig)             shot_cnt <= SHOT_DUR;
            else if (ce_aud && shot_cnt != 9'd0) shot_cnt <= shot_cnt - 9'd1;

            if (boom_trig)             boom_cnt <= BOOM_DUR;
            else if (ce_aud && boom_cnt != 9'd0) boom_cnt <= boom_cnt - 9'd1;
        end
    end
    wire shot_gate = (shot_cnt != 9'd0);
    wire boom_gate = (boom_cnt != 9'd0);

    //=========================================================================
    // Engines (see tank_motor), each on its own channel (MOTOR1 -> R102MX ->
    // OUT1, MOTOR2 -> R106MX -> OUT2).
    //=========================================================================
    wire signed [15:0] motor1;
    wire signed [15:0] motor2;

    tank_motor u_motor1 (
        .clk       (clk),
        .reset     (reset),
        .ce_aud    (ce_aud),
        .speed     (p1_speed),
        .attract   (attract),
        .cab_eq    (cab_eq),
        .putt_trim (putt_trim),
        .volpot    (volpot),
        .motor     (motor1)
    );

    tank_motor u_motor2 (
        .clk       (clk),
        .reset     (reset),
        .ce_aud    (ce_aud),
        .speed     (p2_speed),
        .attract   (attract),
        .cab_eq    (cab_eq),
        .putt_trim (putt_trim),
        .volpot    (volpot),
        .motor     (motor2)
    );

    //=========================================================================
    // Shot and explosion voices: noise x the MC3340 gain.  The one-shot
    // holds the control voltage at a diode level (shot 1.26 V through one
    // 1N914; explosion 1.84 V through CR21 + CR22); then it rises toward
    // 5.53 V with tau = R x C, and the gain follows the MC3340's curve.
    // Fitted to the measured envelopes within 1 dB (shot) / 3 dB
    // (explosion): the shot is full for ~60 ms and gone by 150 ms, the
    // explosion full for ~250 ms and gone by 700 ms.
    //
    // Levels: measured peak shot / explosion 1.23 / 1.26 Vrms against
    // 1.80 Vrms for the engine at speed 6, through equal mixer resistors.
    // The scaling below gives that ratio at the default OSD volumes.
    //=========================================================================
    wire signed [19:0] shot_voice;
    wire signed [19:0] boom_voice;

    tank_voice #(
        .FLOOR_MV (13'd1260),   // one 1N914 + Q7 Vbe (at IC_K6.2)
        .K_RC     (8'd101),     // tau = 0.185 s (R64A 180k x C28A 1uF)
        .KNEE_MV  (13'd2150),   // MC3340 knee (fitted)
        .BRK_MV   (13'd3300),   // slope break (fitted)
        .R1_Q16   (17'd61337),  // 18 dB/V  (per 32 mV LUT step)
        .R2_Q16   (17'd48086)   // 84 dB/V
    ) u_shot_env (
        .clk(clk), .reset(reset), .ce_aud(ce_aud),
        .gate(shot_gate), .noise(noise), .voice(shot_voice)
    );

    tank_voice #(
        .FLOOR_MV (13'd1840),   // CR21 + CR22 in series + Q6 Vbe
        .K_RC     (8'd20),      // tau = 0.937 s (R72A 180k x C41A 5uF)
        .KNEE_MV  (13'd2450),
        .BRK_MV   (13'd3000),
        .R1_Q16   (17'd61790),  // 16 dB/V
        .R2_Q16   (17'd53708)   // 54 dB/V
    ) u_boom_env (
        .clk(clk), .reset(reset), .ce_aud(ce_aud),
        .gate(boom_gate), .noise(noise), .voice(boom_voice)
    );

    //=========================================================================
    // Volume: OSD 0 = Max .. 7 = Mute -> gain 8/8 .. 0
    //=========================================================================
    wire signed [4:0] mvol_g = (master_vol == 3'd7) ? 5'sd0 : (5'sd8 - $signed({2'b00, master_vol}));
    wire signed [4:0] svol_g = (shot_vol   == 3'd7) ? 5'sd0 : (5'sd8 - $signed({2'b00, shot_vol}));
    wire signed [4:0] bvol_g = (boom_vol   == 3'd7) ? 5'sd0 : (5'sd8 - $signed({2'b00, boom_vol}));

    //=========================================================================
    // Mix: per-voice volume with 1 bit of headroom, sum, then master.
    //=========================================================================
    wire signed [24:0] shot_scaled = (shot_voice * svol_g) >>> 4;
    wire signed [24:0] boom_scaled = (boom_voice * bvol_g) >>> 4;

    wire signed [24:0] mix_l = motor1 + shot_scaled + boom_scaled;
    wire signed [24:0] mix_r = motor2 + shot_scaled + boom_scaled;

    wire signed [29:0] out_l = (mix_l * mvol_g) >>> 3;
    wire signed [29:0] out_r = (mix_r * mvol_g) >>> 3;

    //=========================================================================
    // Clamp to signed 16 bits.
    //=========================================================================
    assign audio_l = (out_l >  30'sd32767) ? 16'h7FFF :
                     (out_l < -30'sd32768) ? 16'h8000 :
                                             out_l[15:0];
    assign audio_r = (out_r >  30'sd32767) ? 16'h7FFF :
                     (out_r < -30'sd32768) ? 16'h8000 :
                                             out_r[15:0];

endmodule


//============================================================================
// tank_voice - one shot or explosion voice (MC3340 + diode / RC envelope)
//============================================================================
// On Board I (sheet 2) the 9602 output (an open-collector 7406) pulls the
// MC3340 control pin down through the diode(s) for 3.22 ms; when it lets
// go, C28A / C41A charges through R64A / R72A toward +5 V and the chip's
// dB-linear attenuation closes the voice along that curve.  Modelled as:
//
//   ctrl (mV, Q12):  gate ? FLOOR : ctrl += (5530 - ctrl) * K_RC / 2^20
//   gain = LUT(ctrl): full below KNEE_MV, then two geometric slopes
//                     (R1_Q16 per 32 mV up to BRK_MV, R2_Q16 beyond)
//   voice = noise * gain * 3 >> 3
//
// FLOOR and tau are measured; KNEE, BRK and the slopes are fitted to the
// measured envelopes.
//============================================================================
module tank_voice #(
    parameter [12:0] FLOOR_MV = 13'd1260,  // diode-clamped control floor (mV)
    parameter [7:0]  K_RC     = 8'd101,    // Q20 RC rate: tau = 2^20/(K*55930)
    parameter [12:0] KNEE_MV  = 13'd2150,  // attenuation knee
    parameter [12:0] BRK_MV   = 13'd3300,  // slope break
    parameter [16:0] R1_Q16   = 17'd61337, // gain ratio per 32 mV, knee..brk
    parameter [16:0] R2_Q16   = 17'd48086  // gain ratio per 32 mV, past brk
)(
    input  wire               clk,
    input  wire               reset,
    input  wire               ce_aud,
    input  wire               gate,      // 9602 one-shot active
    input  wire signed [9:0]  noise,     // band-limited noise
    output wire signed [19:0] voice
);
    localparam [24:0] TGT_Q  = {13'd5530, 12'd0};  // recharge target (mV, Q12)

    // control-pin voltage, mV in Q12 fixed point
    reg [24:0] ctrl_q;
    wire signed [25:0] dq   = $signed({1'b0, TGT_Q}) - $signed({1'b0, ctrl_q});
    wire signed [25:0] step = ((dq >>> 8) * $signed({1'b0, K_RC})) >>> 12;
    always @(posedge clk) begin
        if (reset)            ctrl_q <= TGT_Q;            // idle = fully closed
        else if (gate)        ctrl_q <= {FLOOR_MV, 12'd0};
        else if (ce_aud)      ctrl_q <= ctrl_q + step[24:0];
    end

    // MC3340 gain LUT: index = ctrl in 32 mV steps (0..8160 mV)
    reg  [9:0]  vgain [0:255];
    integer     vi;
    reg  [47:0] vacc;
    initial begin
        vacc = 48'd511 << 16;                       // full gain, Q16
        for (vi = 0; vi < 256; vi = vi + 1) begin
            vgain[vi] = vacc[25:16];
            if (vi * 32 >= BRK_MV)
                vacc = (vacc * R2_Q16 + 48'd32768) >> 16;
            else if (vi * 32 >= KNEE_MV)
                vacc = (vacc * R1_Q16 + 48'd32768) >> 16;
            // below the knee: hold full gain
        end
    end
    wire [7:0] idx = ctrl_q[24:17];                 // (mV) >> 5
    wire [9:0] g   = vgain[idx];

    // voice = noise x gain, scaled to the measured mixer ratio
    wire signed [20:0] prod = noise * $signed({1'b0, g});
    assign voice = (prod * 21'sd3) >>> 3;

endmodule


//============================================================================
// tank_motor - one tank's engine
//============================================================================
// From the Board II schematic (audio page) and the engine block of MAME's
// netlist.  Engine 2 (IC_J15 / H15 / F15) has the same parts, so this module
// is used once per tank.
//
//   speed[2:0] -> 7406 open-collector inverters (IC_K15) -> resistor DAC
//     R74M1 / R75M1 / R76M1 (180k / 330k / 680k) with R73M1 22k to +12 V.
//     C54M1 (10 uF) smooths it (the "automatic acceleration" of the
//     schematic's handwritten note); Q27 buffers it: Vctrl.
//
//   Vctrl drives both oscillators:
//     - NE566 (IC_M15): the triangle that sets the engine TONE.  Its output
//       (pin 4) drives the MC3340 gain-control pin.
//     - Q28: a current source charging C51M1 (22 uF) for the NE555 (IC_L15),
//       which discharges it through R77M1 (10k).  Q29 buffers the ramp and
//       C56M1 (5 uF) couples it into the MC3340 audio input: the slow
//       "putt".
//
//   MC3340 (IC_N15): input = the putt ramp, gain = the NE566 triangle.
//     ATTRACT -> 7406 IC_N13 -> Q30 pulls the gain pin high: silent.
//
// More speed -> lower Vctrl -> a higher NE566 tone and more Q28 current, so
// pitch and putt rate rise together.
//
// Measured in nltool on MAME's NE566 / NE555 / MC3340 models (the circuit
// checked pin for pin against Board II Rev F):
//   - NE566 tone 16.9 Hz (speed 0) .. 58.1 Hz (speed 6); a cabinet recording
//     gives 13.4 .. 61 Hz.
//   - acceleration glide ~0.15-0.2 s (C54M1).
//   - attract mutes the MC3340 only; the putt oscillator keeps running.
//   - speed 0 is not silent: Q28 never fully cuts off, so the engine still
//     putts about every 3.7 s.  Putt rate at the factory trim: 0.27 / 0.84 /
//     1.31 / 1.65 / 1.86 / 2.10 / 2.31 Hz for speed 0..6.
//   - the 24 dB exponential gain table below matches the measured
//     harmonic levels within ~1 dB.
//
// Operator trimmers (no single correct value):
//   - putt rate: MOTOR1_VOL2 (1k + 0..100k in Q28's emitter).  charge_step
//     is set at ~10k, which gives the recording's ~2.4 Hz top putt
//     (5k = 3.1, 10k = 2.4, 20k = 1.6, 50k = 0.85, 90k = 0.47 Hz).
//   - MOTOR_DB_SWING ~24 dB: MOTOR1_VOL near ground ("loud").
//   - level against the shot and explosion: MOTOR_VCA_SHIFT.
//============================================================================
module tank_motor (
    input  wire               clk,
    input  wire               reset,
    input  wire               ce_aud,    // ~55.93 kHz audio-rate enable
    input  wire        [2:0]  speed,     // 3-bit speed counter (0..6)
    input  wire               attract,   // 1 = attract mode -> mute
    input  wire               cab_eq,    // 1 = cabinet-speaker model, 0 = circuit output
    input  wire        [2:0]  putt_trim, // MOTOR*_VOL2 position (0 = 10k, factory)
    input  wire        [1:0]  volpot,    // MOTOR*_VOL position (0 = loud, 24 dB)
    output wire signed [15:0] motor      // signed engine sample
);
    //---- constants (see the header) -----------------------------------------
    // MC3340 gain table (see the VCA below).  GPEAK = gain at the triangle's
    // trough; GRATIO = the per-step ratio of the exponential table,
    // round(65536 * 2^(-DB / (6.0206 * 256))), with DB the control swing in
    // dB peak to peak: 24 dB (64832) for MOTOR1_VOL at its loud end.
    localparam [8:0]  MOTOR_GPEAK    = 9'd256;  // MC3340 gain at triangle trough (max)
    localparam [16:0] MOTOR_GRATIO   = 17'd64832; // exp-LUT step ratio, MOTOR_DB_SWING = 24 dB
    localparam        MOTOR_VCA_SHIFT = 9;      // output level (lower = louder); speed-6 peak ~7k
    localparam        CAB_SHIFT       = 13;     // cabinet-model level; matches the circuit output's peak
    // Cabinet-model pitch: the cabinet recording runs at 13.4 .. 61 Hz
    // against the circuit's 16.9 .. 58.1 Hz (within part tolerance).  The
    // cabinet model follows the recording: inc_cab = (inc566 * K) >> 8 - C
    // passes through both points (13.40 / 60.93 Hz).  The circuit output
    // keeps the circuit's pitch.
    localparam [8:0]  CAB_PITCH_K     = 9'd298;  // increment scale (Q8: 1.164x)
    localparam [23:0] CAB_PITCH_C     = 24'd1900; // increment offset

    //---- speed DAC ----------------------------------------------------------
    // 12 V - Vctrl in millivolts for each speed (measured at Q27's emitter).
    // Both oscillators follow dv.
    reg [11:0] dv_code;
    always @(*) begin
        case (speed)
            3'd0:    dv_code = 12'd740;   // Vctrl 11.260 V  -> NE566 16.94 Hz
            3'd1:    dv_code = 12'd1104;  // Vctrl 10.896 V  -> NE566 25.05 Hz
            3'd2:    dv_code = 12'd1468;  // Vctrl 10.532 V  -> NE566 33.14 Hz
            3'd3:    dv_code = 12'd1789;  // Vctrl 10.211 V  -> NE566 40.27 Hz
            3'd4:    dv_code = 12'd2010;  // Vctrl  9.990 V  -> NE566 45.19 Hz
            3'd5:    dv_code = 12'd2301;  // Vctrl  9.699 V  -> NE566 51.62 Hz
            default: dv_code = 12'd2593;  // speed 6 (counter caps at 6) 58.13 Hz
        endcase
    end

    // C54M1 (10 uF) acceleration glide: one-pole low-pass, tau ~0.15 s.
    // dv_s is 12.12 fixed point; integer millivolts are dv_s[23:12].
    reg  signed [25:0] dv_s;
    wire signed [25:0] dv_tgt = $signed({2'b00, dv_code, 12'd0});
    always @(posedge clk) begin
        if (reset)       dv_s <= $signed({2'b00, 12'd740, 12'd0});
        else if (ce_aud) dv_s <= dv_s + ((dv_tgt - dv_s) >>> 13);
    end
    wire [11:0] dv = dv_s[23:12];

    //---- NE566 triangle = engine tone ---------------------------------------
    // Measured: f566 = 22.0 x dv[V] + 0.65 Hz.  (R36M1 = 100k is outside the
    // range of the datasheet formula, which would give 16.667 x dv.)  For a
    // 24-bit phase accumulator at ce_aud: inc = (dv * 423) >> 6 + 195,
    // within 0.6 % of all seven measured points.
    reg  [23:0] ph566;
    wire [23:0] inc566 = ((dv * 24'd423) >> 6) + 24'd195;
    always @(posedge clk) begin
        if (reset)       ph566 <= 24'd0;
        else if (ce_aud) ph566 <= ph566 + inc566;
    end
    // symmetric triangle, 0..65535
    wire [15:0] tri566 = ph566[23] ? ~ph566[22:7] : ph566[22:7];

    //---- NE555 oscillator = the "putt" --------------------------------------
    // Q28's current charges C51M1; the 555 empties it through R77M1 (10k) in
    // a fixed ~0.19 s.  Only the charge rate depends on speed.  Measured
    // (factory trim): charge_step = max((dv * 5) >> 4 - 195, 43), giving putt
    // periods of 3.71 / 1.19 / 0.76 / 0.61 / 0.54 / 0.48 / 0.43 s for speed
    // 0..6, within ~1 %.  The floor is Q28's leakage at speed 0.
    wire [23:0] dv_q     = ({12'd0, dv} * 24'd5) >> 4;
    wire [23:0] charge_step = (dv_q > 24'd238) ? (dv_q - 24'd195) : 24'd43;

    // MOTOR*_VOL2 putt-rate trimmer (1k + 0..100k in Q28's emitter): the
    // charge current scales as (1k + 10k) / (1k + R) from the 10k factory
    // setting, the leakage floor included.
    reg [9:0] putt_k;                       // Q8: (1k+10k)/(1k+R)
    always @(*) begin
        case (putt_trim)
            3'd1:    putt_k = 10'd469;      //  5k trim -> 3.1 Hz top putt
            3'd2:    putt_k = 10'd134;      // 20k trim -> 1.6 Hz
            3'd3:    putt_k = 10'd55;       // 50k trim -> 0.85 Hz
            3'd4:    putt_k = 10'd31;       // 90k trim -> 0.47 Hz
            default: putt_k = 10'd256;      // 10k reference -> 2.4 Hz (factory)
        endcase
    end
    wire [23:0] charge_eff = (charge_step * putt_k) >> 8;

    localparam [23:0] CAP_HI         = 24'd12582912; // 555 threshold (2/3 Vcc)
    localparam [23:0] CAP_LO         = 24'd4194304;  // 555 trigger   (1/3 Vcc)
    localparam [23:0] DISCHARGE_STEP = 24'd789;      // R77M1 x C51M1: 0.19 s (measured)

    reg  [23:0] cap;            // C51M1 voltage
    reg         discharging;
    always @(posedge clk) begin
        if (reset) begin
            cap         <= CAP_LO;
            discharging <= 1'b0;
        end else if (ce_aud) begin
            if (discharging) begin
                if (cap <= CAP_LO + DISCHARGE_STEP) begin
                    cap         <= CAP_LO;
                    discharging <= 1'b0;
                end else begin
                    cap <= cap - DISCHARGE_STEP;
                end
            end else if (charge_eff != 24'd0) begin
                if (cap >= CAP_HI - charge_eff) begin
                    cap         <= CAP_HI;
                    discharging <= 1'b1;
                end else begin
                    cap <= cap + charge_eff;
                end
            end
        end
    end

    // C56M1 (5 uF) AC-couples the ramp into the MC3340: a one-pole ~2 Hz
    // high-pass (the ramp minus its running mean).
    wire signed [17:0] cap_ac_in = $signed({2'b00, cap[23:8]});
    reg  signed [17:0] cap_lp;
    always @(posedge clk) begin
        if (reset)       cap_lp <= 18'sd0;
        else if (ce_aud) cap_lp <= cap_lp + ((cap_ac_in - cap_lp) >>> 12);
    end
    wire signed [17:0] carrier = cap_ac_in - cap_lp;

    //---- MC3340 (dB-linear, -30 dB/V) ---------------------------------------
    // The NE566 triangle drives the control pin, and the gain is linear in
    // dB: gain_dB = 13 - 30 x (Vctrl - 1), within -80..+13 (Motorola
    // datasheet).  This exponential gain on a triangle is what gives the
    // engine its even harmonics and its energy in the audible 80-320 Hz
    // band; the fundamental itself is only 17-58 Hz.
    //
    // gain[idx] = MOTOR_GPEAK * 2^-(idx/256 * MOTOR_DB_SWING / 6.0206), idx =
    // tri566[15:8], built as an integer series so it synthesises as a
    // 256 x 9 ROM.  ATTRACT mutes it.
    reg  [8:0]  vca_gain [0:255];
    integer     gi;
    reg  [47:0] gacc;
    initial begin
        gacc = MOTOR_GPEAK << 16;                       // Q16 fixed point
        for (gi = 0; gi < 256; gi = gi + 1) begin
            vca_gain[gi] = gacc[24:16];
            gacc = (gacc * MOTOR_GRATIO + 48'd32768) >> 16;
        end
    end
    // MOTOR*_VOL pot: attenuates the triangle into the control pin.
    // Modelled as a narrower swing of the table index about its centre: the
    // same 24 dB curve over a smaller control range, which lowers the peak
    // gain and raises the minimum together, as an attenuator there does.
    // Only the loud end (24 dB) is checked against a recording.
    reg [8:0] vol_k;                        // Q8 swing fraction
    always @(*) begin
        case (volpot)
            2'd1:    vol_k = 9'd192;        // 18 dB swing
            2'd2:    vol_k = 9'd128;        // 12 dB
            2'd3:    vol_k = 9'd64;         //  6 dB (quiet end)
            default: vol_k = 9'd256;        // 24 dB, loud end (factory)
        endcase
    end
    wire signed [9:0]  tri_c   = $signed({2'b00, tri566[15:8]}) - 10'sd128;
    wire signed [19:0] tri_s   = tri_c * $signed({1'b0, vol_k});
    wire signed [11:0] tri_sh  = tri_s >>> 8;             // [-128, 127]
    wire [7:0]         tri_idx = 8'd128 + tri_sh[7:0];
    wire [8:0] g = attract ? 9'd0 : vca_gain[tri_idx];

    wire signed [27:0] vca   = carrier * $signed({1'b0, g});
    wire signed [27:0] vca_s = vca >>> MOTOR_VCA_SHIFT;

    // the circuit's output (cab_eq = 0)
    wire signed [15:0] motor_raw = (vca_s >  28'sd32767) ? 16'sh7FFF :
                                   (vca_s < -28'sd32768) ? 16'sh8000 :
                                                           vca_s[15:0];

    //=========================================================================
    // Cabinet-speaker model (cab_eq = 1)
    //=========================================================================
    // A small cabinet speaker cannot reproduce the 13-61 Hz engine tone; what
    // it gives out is the tone's harmonics, the mid-band buzz of cabinet
    // recordings (spectral centroid ~285 Hz).  The circuit's signal has its
    // energy at the fundamental, and no linear filter can add harmonics, so
    // this models the speaker: a sawtooth at the engine pitch (harmonics
    // 1/n), shaped by the engine's slow envelope (putt and speed), then
    // band-passed to ~130 Hz - 2.5 kHz.  This matches the recordings'
    // centroid and roll-off.
    //
    // Its pitch comes from a separate phase accumulator at the recording's
    // frequency (see CAB_PITCH_K / CAB_PITCH_C); ph566 still drives the
    // envelope and the circuit output.
    wire [33:0] cab_pmul = inc566 * CAB_PITCH_K;
    wire [23:0] cab_ps   = cab_pmul[31:8];                  // (inc566*K)>>8
    wire [23:0] inc_cab  = (cab_ps > CAB_PITCH_C) ? (cab_ps - CAB_PITCH_C) : 24'd1;
    reg  [23:0] ph_cab;
    always @(posedge clk) begin
        if (reset)       ph_cab <= 24'd0;
        else if (ce_aud) ph_cab <= ph_cab + inc_cab;
    end

    // sawtooth at the cabinet pitch (phase -> two's complement)
    wire signed [15:0] saw = {~ph_cab[23], ph_cab[22:8]};

    // slow envelope of the circuit output (|motor_raw| low-passed at ~8 Hz)
    wire signed [16:0] m_se  = {motor_raw[15], motor_raw};
    wire signed [16:0] m_abs = m_se[16] ? -m_se : m_se;
    reg  signed [16:0] env;
    always @(posedge clk) begin
        if (reset)       env <= 17'sd0;
        else if (ce_aud) env <= env + ((m_abs - env) >>> 10);   // ~8.7 Hz one-pole LP
    end

    // sawtooth x envelope, scaled to the circuit output's level
    wire signed [32:0] bright_full = saw * env;
    wire signed [20:0] bright      = bright_full >>> CAB_SHIFT;

    // speaker band-pass: 1-pole HP ~139 Hz (DC blocker) + 1-pole LP ~2.56 kHz
    reg signed [20:0] bp_xp, bp_hp, bp_lp;
    wire signed [20:0] bp_hpn = bright - bp_xp + bp_hp - (bp_hp >>> 6);
    always @(posedge clk) begin
        if (reset) begin
            bp_xp <= 21'sd0; bp_hp <= 21'sd0; bp_lp <= 21'sd0;
        end else if (ce_aud) begin
            bp_xp <= bright;
            bp_hp <= bp_hpn;
            bp_lp <= bp_lp + ((bp_hp - bp_lp) >>> 2);
        end
    end
    wire signed [15:0] motor_cab = (bp_lp >  21'sd32767) ? 16'sh7FFF :
                                   (bp_lp < -21'sd32768) ? 16'sh8000 :
                                                           bp_lp[15:0];

    assign motor = cab_eq ? motor_cab : motor_raw;

endmodule
