//============================================================================
//
//  Tank (Kee Games / Atari, 1974) - MiSTer FPGA Core
//
//  MiSTer top level: OSD menu, clocks, ROM download, the Tank boards
//  (tank_core), video output with CRT Adjust, the cocktail / Flip
//  framebuffer, and the two speaker channels.
//
//  Copyright (C) 2026 RetroShrimp
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//============================================================================

module emu
(
    // Port list from the MiSTer framework.  The cocktail rotation and Flip
    // use the MISTER_FB / MISTER_FB_PALETTE ports.
    `include "sys/emu_ports.vh"
);

    ///////// Default values for ports not used in this core /////////

    assign ADC_BUS  = 'Z;
    assign USER_OUT = '1;
    assign {UART_RTS, UART_TXD, UART_DTR} = 0;
    assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
    assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
    // DDRAM holds the HDMI framebuffer (see VIDEO ORIENTATION below) when
    // MISTER_FB is defined; otherwise unused.
`ifndef MISTER_FB
    assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;
`endif

    assign VGA_SL = 0;
    // VGA_F1 (interlace field flag) is driven below in the VIDEO OUTPUT section.
    assign VGA_SCALER  = 0;
    assign VGA_DISABLE = 0;
    assign HDMI_FREEZE = 0;
    assign HDMI_BLACKOUT = 0;
    assign HDMI_BOB_DEINT = 0;

    assign AUDIO_S = 1;          // signed samples
    assign AUDIO_L = audio_l;
    assign AUDIO_R = audio_r;
    // The cabinet has two speakers, one per tank, with no cross-mix: the
    // harness (003492 upright, 004032 cocktail) wires AUDIO-1 and AUDIO-2
    // from the Board I edge connector (J3 pins 17/16) to separate speakers,
    // and the monitor's own audio is unused.  Left = black tank, right =
    // white tank.
    assign AUDIO_MIX = 2'd0;

    assign LED_DISK = 0;
    assign LED_POWER = 0;
    assign BUTTONS = 0;

    //////////////////////////////////////////////////////////////////

    wire [1:0] ar = status[122:121];
    wire       video_rotated;            // 1 = cocktail (90-degree) rotation active

    // Original aspect: 4:3, or 3:4 when the cocktail rotation turns the
    // picture.  video_freak applies it together with the Scale option.
    wire [11:0] arx = (!ar) ? (video_rotated ? 12'd3 : 12'd4) : 12'(ar - 1'd1);
    wire [11:0] ary = (!ar) ? (video_rotated ? 12'd4 : 12'd3) : 12'd0;

    `include "build_id.v"
    localparam CONF_STR = {
        "Tank;;",
        "-;",
        "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
        // Orientation and Scale act on the HDMI picture only.
        "O[4],Orientation,Original,Flip;",
        "O[3:1],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer;",
        "O[16],Maze,Original,Alternate;",
        "O[17],Coin Mode,25c,50c;",
        // MRA <switches>: Monitor (Upright / Cocktail CW / Cocktail CCW),
        // defaulted by each MRA.
        "DIP;",
        "-;",
        "O[8:6],Master Volume,Max,7,6,5,4,3,2,Mute;",
        "O[11:9],Missile Volume,Max,7,6,5,4,3,2,Mute;",
        "O[14:12],Explosion Volume,Max,7,6,5,4,3,2,Mute;",
        "O[15],Cabinet Speaker,On,Off;",
        "-;",
        // Operator Adjust: the board's pots and trimmers; option 0 is the
        // factory setting.  Play Time shows "25c/50c seconds": one pot sets
        // both, through the coin-mode switch (222k vs 680k in series).  A
        // real pot set for 60 s gives about 110 s at 50c; the factory option
        // keeps the manual's nominal 60/120.
        "P1,Operator Adjust;",
        "P1O[20:18],White Missile Range,Mid 0.39s,Min 0.01s,Short 0.2s,Long 0.57s,Max 0.76s;",
        "P1O[23:21],Play Time Pot,Factory 60/120,Min 24/74s,35/85s,46/96s,60/110s,79/129s,106/157s,Max 134/184s;",
        "P1O[26:24],Engine Putt Trim,Ref 2.4Hz,Fast 3.1Hz,Slow 1.6Hz,Slower 0.9Hz,Min 0.5Hz;",
        "P1O[28:27],Engine Vol Pot,Loud 24dB,18dB,12dB,Quiet 6dB;",
        // CRT Adjust (see VIDEO OUTPUT below): analog geometry for 15 kHz
        // CRTs.  H1 hides the amounts until it is On.  Steps: H-Size 1/64
        // of the picture width (~1.6 %), H-Position one pixel (70 ns),
        // V-Shift one line.
        "P2,CRT Adjust (analog);",
        "P2O[30],CRT Adjust,Off,On;",
        "H1P2O[35:31],H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,",
            "-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "H1P2O[42:36],H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,",
            "+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,",
            "+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,",
            "-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,",
            "-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,",
            "-8,-7,-6,-5,-4,-3,-2,-1;",
        "H1P2O[47:43],V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,",
            "-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "-;",
        // Menu items must come before the J1 / V lines: items placed after
        // them are shown but never bound to their status bit.
        "T[0],Reset;",
        "J1,R_FWD,R_REV,L_FWD,L_REV,Fire,Start,Coin;",
        "V,v",`BUILD_DATE
    };

    wire forced_scandoubler;
    wire   [1:0] buttons;
    wire [127:0] status;
    wire  [10:0] ps2_key;

    // ROM download from the MiSTer (HPS -> FPGA)
    wire        ioctl_download;
    wire [15:0] ioctl_index;
    wire        ioctl_wr;
    wire [26:0] ioctl_addr;
    wire  [7:0] ioctl_dout;

    wire [31:0] joystick_0;
    wire [31:0] joystick_1;

    hps_io #(.CONF_STR(CONF_STR)) hps_io
    (
        .clk_sys(clk_sys),
        .HPS_BUS(HPS_BUS),
        .EXT_BUS(),
        .gamma_bus(),

        .forced_scandoubler(forced_scandoubler),

        .buttons(buttons),
        .status(status),
        .status_menumask({~status[30], status[5]}),   // [1]: H1 = CRT Adjust amounts

        .ps2_key(ps2_key),

        .ioctl_download(ioctl_download),
        .ioctl_index   (ioctl_index),
        .ioctl_wr      (ioctl_wr),
        .ioctl_addr    (ioctl_addr),
        .ioctl_dout    (ioctl_dout),
        .ioctl_wait    (1'b0),       // always ready to accept data
        
        .joystick_0    (joystick_0),
        .joystick_1    (joystick_1)
    );

    ///////////////////////   CLOCKS   ///////////////////////////////

    // clk_sys = 14.318181 MHz, the board's master crystal (4 x the NTSC
    // colour subcarrier).  The game runs entirely on this clock, as the
    // board does: 904 clocks a line, 260.5 lines a field (15.84 kHz,
    // 60.80 Hz).  clk_vid = 6 x clk_sys from the same VCO is CLK_VIDEO, so
    // CRT Adjust can read its line buffer in steps finer than a pixel.
    wire clk_sys;
    wire clk_vid;
    wire pll_locked;

    pll pll
    (
        .refclk(CLK_50M),
        .rst(0),
        .outclk_0(clk_sys),
        .outclk_1(clk_vid),
        .locked(pll_locked)
    );

    wire reset = RESET | status[0] | buttons[1];

    ///////////////////////   MRA DOWNLOADS   //////////////////////////
    //
    // ioctl index 0   = the K10 ROM.  Only the first 2 KB are written:
    //                   MAME's tankii set is the same image plus one
    //                   trailing 0xFF byte, which would wrap onto ROM[0].
    // ioctl index 254 = the MRA <switches> bytes, kept out of the ROM.
    wire rom_wr = ioctl_wr && (ioctl_index[7:0] == 8'd0) && (ioctl_addr[26:11] == 16'd0);

    // DIP byte 0, bits [1:0] = Monitor: 0 = Upright (Tank, Tank II),
    // 1 = Cocktail CW, 2 = Cocktail CCW (Tank Cocktail: the monitor lies
    // face up, turned 90 degrees between the two players).
    reg [7:0] dip0 = 8'h00;
    always @(posedge clk_sys)
        if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && (ioctl_addr[26:0] == 27'd0))
            dip0 <= ioctl_dout;

    // HDMI orientation = the Monitor setting, turned 180 degrees more by the
    // OSD Flip: Upright -> 180 (tank_rotate mode 3), Cocktail CW <-> CCW.
    wire       osd_flip    = status[4];
    wire [1:0] orientation = !osd_flip         ? dip0[1:0] :
                             (dip0[1:0] == 2'd1) ? 2'd2 :      // CW  + 180 = CCW
                             (dip0[1:0] == 2'd2) ? 2'd1 :      // CCW + 180 = CW
                                                   2'd3;       // Upright + 180

    ///////////////////////   TANK CORE   ////////////////////////////

    wire       HBlank;
    wire       HSync;
    wire       VBlank;
    wire       VSync;
    wire       ce_pix;
    wire       de;
    wire [7:0] video_r;
    wire [7:0] video_g;
    wire [7:0] video_b;

    // OSD settings
    wire  [2:0] master_vol = status[8:6];
    wire  [2:0] shot_vol   = status[11:9];
    wire  [2:0] boom_vol   = status[14:12];
    wire        cab_eq     = ~status[15];   // Cabinet Speaker: 1 = On (default)
    wire        maze_sel   = status[16];    // 0 = Original maze, 1 = Alternate
    wire        game_time_120 = status[17]; // Coin Mode: 0 = 25c (60 s, one coin),
                                            // 1 = 50c (120 s, two coins)
    // Operator Adjust (0 = factory setting)
    wire  [2:0] fire1_range = status[20:18]; // FIRE1_ADJUST pot: the white tank's
                                             // missile range (the black tank's is fixed)
    wire  [2:0] play_pot    = status[23:21]; // PLAYTIME pot
    wire  [2:0] putt_trim   = status[26:24]; // engine putt-rate trimmer
    wire  [1:0] volpot_trim = status[28:27]; // engine volume pot
    wire        field;                      // interlace field flag -> VGA_F1
    wire [15:0] audio_l;
    wire [15:0] audio_r;

    // One pixel per clk_sys cycle, as on the board (the clk_vid output
    // has its own enable, ce_vid, below).
    assign ce_pix = 1'b1;

    tank_core u_tank_core (
        .clk_pix        (clk_sys),
        .reset          (reset),
        .ioctl_download (ioctl_download),
        .ioctl_wr       (rom_wr),
        .ioctl_addr     (ioctl_addr),
        .ioctl_dout     (ioctl_dout),
        .hsync          (HSync),
        .vsync          (VSync),
        .hblank         (HBlank),
        .vblank         (VBlank),
        .de             (de),
        .video_r        (video_r),
        .video_g        (video_g),
        .video_b        (video_b),
        .joystick_0     (joystick_0),
        .joystick_1     (joystick_1),
        .master_vol     (master_vol),
        .shot_vol       (shot_vol),
        .boom_vol       (boom_vol),
        .cab_eq         (cab_eq),
        .maze_sel       (maze_sel),
        .game_time_120  (game_time_120),
        .fire1_range    (fire1_range),
        .play_pot       (play_pot),
        .putt_trim      (putt_trim),
        .volpot_trim    (volpot_trim),
        .field          (field),
        .audio_l        (audio_l),
        .audio_r        (audio_r)
    );

    ///////////////////////   VIDEO OUTPUT   //////////////////////////
    //
    // CLK_VIDEO = clk_vid (85.909 MHz, 6 x the pixel clock), CE_PIXEL one
    // pulse per pixel.  The faster clock is for CRT Adjust (crt_adjust.sv,
    // from github.com/rmonic79/MiSTer-CRT-Adjust), whose H-Size reads a line
    // buffer in fractions of a pixel.  (Not 8x: at 114.5 MHz the
    // framework's composite encoder, also on CLK_VIDEO, misses timing.)
    //
    // CRT Adjust Off: VGA_* is the native raster, re-registered into clk_vid.
    // CRT Adjust On (analog geometry for a 15 kHz CRT):
    //   H-Size     -- read rate (64 + n)/64: 75 % .. 123 % wide, HSync
    //                 unchanged.  The picture grows from the HSync edge and
    //                 already fills 870 of the 904 clocks, so above +1 the
    //                 right edge is cut at the next HSync; pair a wider
    //                 setting with a negative H-Position.
    //   H-Position -- moves the picture n pixels inside the line buffer,
    //                 HSync unchanged.  Past +33 the right edge is cut.
    //   V-Shift    -- delays VSync (and VGA_F1) by n lines; a negative n is
    //                 a delay of one frame (521 lines) minus |n|, which keeps
    //                 the field parity.
    // The line buffer adds one line of latency.  HDMI sees the same stream:
    // H-Size and H-Position barely show there, but V-Shift moves VSync into
    // the picture (the vertical blank is only ~8 lines) and the image wraps,
    // so leave CRT Adjust Off for HDMI.  It is disabled while the
    // scandoubler is forced (31 kHz VGA).  The HDMI framebuffer (below)
    // takes the native raster, so a rotated or flipped picture never sees
    // CRT Adjust.

    assign CLK_VIDEO = clk_vid;

    // 1. Register the native raster on clk_sys (video_r is combinational in
    //    tank_core) and toggle a flag every clk_sys cycle.
    reg [7:0] nat_pix = 8'd0;
    reg       nat_hs = 1'b0, nat_vs = 1'b0, nat_de = 1'b0, nat_vb = 1'b1, nat_fl = 1'b0;
    reg       nat_tog = 1'b0;
    always @(posedge clk_sys) begin
        nat_pix <= video_r;              // R = G = B (grayscale raster)
        nat_hs  <= HSync;
        nat_vs  <= VSync;
        nat_de  <= de;
        nat_vb  <= VBlank;
        nat_fl  <= field;
        nat_tog <= ~nat_tog;
    end

    // 2. Into clk_vid.  Both clocks come off one VCO and every clk_sys edge
    //    coincides with a clk_vid edge, so Quartus times this as an ordinary
    //    synchronous transfer (one clk_vid period, 11.6 ns).  ce_vid pulses
    //    for one clk_vid cycle per clk_sys cycle, one cycle after the new
    //    values land.
    reg [7:0] vid_pix = 8'd0;
    reg       vid_hs = 1'b0, vid_vs = 1'b0, vid_de = 1'b0, vid_vb = 1'b1, vid_fl = 1'b0;
    reg       tog_q = 1'b0, tog_qq = 1'b0;
    always @(posedge clk_vid) begin
        vid_pix <= nat_pix;
        vid_hs  <= nat_hs;
        vid_vs  <= nat_vs;
        vid_de  <= nat_de;
        vid_vb  <= nat_vb;
        vid_fl  <= nat_fl;
        tog_q   <= nat_tog;
        tog_qq  <= tog_q;
    end
    wire ce_vid = tog_q ^ tog_qq;

    // 3. OSD values (P2 page).
    reg              crt_on     = 1'b0;
    reg signed [4:0] crt_hsize  = 5'sd0;    // -16..+15
    reg        [6:0] crt_hpos_i = 7'd0;     // OSD index 0..96
    reg signed [5:0] crt_vshift = 6'sd0;    // -16..+15
    always @(posedge clk_vid) if (ce_vid) begin
        crt_on     <= status[30] & ~forced_scandoubler;
        crt_hsize  <= $signed(status[35:31]);
        crt_hpos_i <= status[42:36];
        crt_vshift <= $signed(status[47:43]);
    end
    // H-Position list is 0,+1..+48,-48..-1 (97 entries): index 0..48 = +n,
    // 49..96 = n - 97.
    wire signed [8:0] crt_hpos = (crt_hpos_i <= 7'd48)
                               ? $signed({2'b00, crt_hpos_i})
                               : $signed({2'b00, crt_hpos_i}) - 9'sd97;

    // 4. Read clock enable: one tick every (192 + 3 x hsize) / 32 clk_vid
    //    cycles, i.e. every (64 + hsize)/64 pixels (a pixel is 6 clk_vid =
    //    192 / 32).  Restarted at each rise of hs_ref_out, so every line
    //    reads with the same phase and the picture cannot drift.
    wire       crt_hs_ref;
    reg        crt_hs_ref_d = 1'b0;
    always @(posedge clk_vid) crt_hs_ref_d <= crt_hs_ref;
    wire       crt_hs_ref_rise = crt_hs_ref & ~crt_hs_ref_d;

    wire signed [8:0] rd_hs3 = 9'sd3 * crt_hsize;                   // -48..+45
    wire [7:0] rd_period = 8'd192 + rd_hs3[7:0];                     // 144..237
    reg  [7:0] rd_acc    = 8'd0;
    wire [8:0] rd_acc_n  = {1'b0, rd_acc} + 9'd32;
    wire       rd_tick   = (rd_acc_n >= {1'b0, rd_period});
    wire [8:0] rd_acc_w  = rd_acc_n - {1'b0, rd_period};
    always @(posedge clk_vid) begin
        if      (crt_hs_ref_rise) rd_acc <= 8'd0;
        else if (rd_tick)         rd_acc <= rd_acc_w[7:0];
        else                      rd_acc <= rd_acc_n[7:0];
    end
    wire rd_ce = crt_on ? rd_tick : ce_vid;

    // 5. The module.  Content-shift mode suits Tank's centred 774-pixel
    //    picture (HSync stays native).  VTOTAL = 521 lines = one frame (see
    //    V-Shift above).  AW = 11 for the 904-pixel line.  Gray only, so G
    //    and B are not stored.
    wire [7:0] crt_pix;
    wire       crt_hs, crt_vs, crt_hb, crt_fl;

    crt_adjust #(
        .VTOTAL    (521),
        .HTOTAL    (904),
        .HPOS_MODE (1),               // HPOS_CONTENTSHIFT
        .AW        (11)
    ) u_crt_adjust (
        .clk        (clk_vid),
        .pxl_cen    (ce_vid),
        .pxl2_cen   (rd_ce),
        .active     (crt_on),
        .hsize      (crt_hsize),
        .hoffset    (crt_hpos),
        .voffset    (crt_vshift),
        .r_in       (vid_pix),
        .g_in       (8'd0),
        .b_in       (8'd0),
        .hs_in      (vid_hs),
        .vs_in      (vid_vs),
        .hb_in      (~vid_de),        // horizontal window = the explicit DE
        .vb_in      (vid_vb),         // TRUE vertical blank (upstream rule)
        .r_out      (crt_pix),
        .g_out      (),
        .b_out      (),
        .hs_out     (crt_hs),
        .vs_out     (crt_vs),
        .hb_out     (crt_hb),
        .vb_out     (),
        .hs_ref_out (crt_hs_ref),
        .fl_in      (vid_fl),
        .fl_out     (crt_fl)
    );

    // 6. Outputs.
    assign CE_PIXEL = crt_on ? rd_ce   : ce_vid;
    wire   vga_de_raw = crt_on ? ~crt_hb : vid_de;
    assign VGA_HS   = crt_on ? crt_hs  : vid_hs;
    assign VGA_VS   = crt_on ? crt_vs  : vid_vs;
    assign VGA_R    = crt_on ? crt_pix : vid_pix;
    assign VGA_G    = VGA_R;
    assign VGA_B    = VGA_R;

    // 7. Scale (O[3:1]) through the framework's video_freak: Normal /
    //    V-Integer / HV-Integer / Narrower HV-Integer = SCALE 0 / 1 / 4 / 2.
    //    video_freak measures the raster on VGA_DE (774 x 252 per field).
    //    The scaler shows Original as 774 x 504 (both fields woven), the
    //    same frame the Flip framebuffer holds, so both scale alike.  The
    //    cocktail framebuffer is 504 x 774, so there Scale stays Normal
    //    rather than size the picture from the wrong axes.
    wire [2:0] scale_osd = status[3:1];
    wire [2:0] scale_sel = video_rotated         ? 3'd0 :
                           (scale_osd == 3'd0)   ? 3'd0 :
                           (scale_osd == 3'd1)   ? 3'd1 :
                           (scale_osd == 3'd2)   ? 3'd4 :
                                                   3'd2;

    video_freak video_freak
    (
        .CLK_VIDEO   (CLK_VIDEO),
        .CE_PIXEL    (CE_PIXEL),
        .VGA_VS      (VGA_VS),
        .HDMI_WIDTH  (HDMI_WIDTH),
        .HDMI_HEIGHT (HDMI_HEIGHT),
        .VGA_DE      (VGA_DE),
        .VIDEO_ARX   (VIDEO_ARX),
        .VIDEO_ARY   (VIDEO_ARY),
        .VGA_DE_IN   (vga_de_raw),
        .ARX         (arx),
        .ARY         (ary),
        .CROP_SIZE   (12'd0),
        .CROP_OFF    (5'd0),
        .SCALE       (scale_sel)
    );

    ///////////////////////   VIDEO ORIENTATION (Cocktail)   //////////
    //
    // Tank Cocktail uses the same two boards as the upright, so the video
    // is identical; only the monitor lies face up, turned 90 degrees between
    // the players.  CW puts the raster's right edge (the white tank's side)
    // toward the white player.  That comes from a photo of a table, not a
    // drawing, so CCW is offered too.
    //
    // tank_rotate writes the raster into a DDR3 framebuffer (8 bpp gray)
    // that the scaler shows on HDMI; the analog output is never rotated.
    // The two interlaced fields are woven into one 774 x 504 frame, which is
    // shown as it is (upright) or turned 90 degrees (504 x 774, cocktail) or
    // 180 degrees (OSD Flip on an upright).  The upright picture goes through
    // the framebuffer too: the scaler's own weave needs at least 504 output
    // lines and below that shows the fields one at a time.  The framework's
    // screen_rotate is not used: its one write per pixel loses pixels
    // whenever the DDR3 port stalls.
`ifdef MISTER_FB
    assign FB_FORCE_BLANK = 1'b0;

    tank_rotate u_rotate
    (
        .clk            (clk_sys),       // native raster, before CRT Adjust
        .ce             (ce_pix),
        .pix            (video_r),       // R = G = B (grayscale raster)
        .vs             (VSync),
        .de             (de),
        .fl             (field),         // 1 = the field drawn half a line lower
        .mode           (orientation),
        .video_rotated  (video_rotated),

        .FB_EN          (FB_EN),
        .FB_FORMAT      (FB_FORMAT),
        .FB_WIDTH       (FB_WIDTH),
        .FB_HEIGHT      (FB_HEIGHT),
        .FB_BASE        (FB_BASE),
        .FB_STRIDE      (FB_STRIDE),
        .FB_VBL         (FB_VBL),
        .FB_LL          (FB_LL),

    `ifdef MISTER_FB_PALETTE
        .FB_PAL_CLK     (FB_PAL_CLK),
        .FB_PAL_ADDR    (FB_PAL_ADDR),
        .FB_PAL_DOUT    (FB_PAL_DOUT),
        .FB_PAL_WR      (FB_PAL_WR),
    `else
        .FB_PAL_CLK     (),
        .FB_PAL_ADDR    (),
        .FB_PAL_DOUT    (),
        .FB_PAL_WR      (),
    `endif

        .DDRAM_CLK      (DDRAM_CLK),
        .DDRAM_BUSY     (DDRAM_BUSY),
        .DDRAM_BURSTCNT (DDRAM_BURSTCNT),
        .DDRAM_ADDR     (DDRAM_ADDR),
        .DDRAM_DIN      (DDRAM_DIN),
        .DDRAM_BE       (DDRAM_BE),
        .DDRAM_WE       (DDRAM_WE),
        .DDRAM_RD       (DDRAM_RD)
    );
`else
    assign video_rotated = 1'b0;
`endif

    ///////////////////////   INTERLACE   ////////////////////////////
    //
    // Tank's raster is interlaced: 521 half-lines a field (260.5 lines,
    // 60.80 Hz), so alternate fields start half a line apart.  VSync keeps
    // the board's half-line timing (a CRT interlaces), DE spans whole lines
    // (the scaler counts them), and VGA_F1 marks the field.
    assign VGA_F1 = crt_on ? crt_fl : vid_fl;   // CRT Adjust: follows V-Shift

    ///////////////////////   STATUS LED   ///////////////////////////

    assign LED_USER = ioctl_download;

endmodule
