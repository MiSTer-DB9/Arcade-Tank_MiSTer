//============================================================================
//  tank_rotate - HDMI framebuffer: woven fields, upright (0 degrees), cocktail
//                (90 degrees) or OSD Flip (180 degrees); 8 bpp, 8 pixels per write
//
//  Used instead of the framework's screen_rotate, which writes one pixel
//  per clock to scattered DDR3 addresses and ignores DDRAM_BUSY: at Tank's
//  14.318 MHz pixel rate it loses pixels whenever the port stalls.
//
//  Tank's picture is grayscale, so the framebuffer is 8 bpp with an
//  identity gray palette (exact).
//
//  WEAVE.  Tank is interlaced, and its two fields are not the same picture:
//  in the field drawn half a line lower (fl = 1) the content row advances
//  part-way along each line.  Rotating each field into the same rows would
//  move part of the picture by a row every other field.  So the two fields
//  are woven into one frame of 2H rows: line y of field fl is source row
//  s = 2y + fl.  A frame is an fl = 0 field followed by an fl = 1 field,
//  written into one buffer.  The upright picture is woven here too: the
//  scaler weaves only when its output has at least 2H lines and below that
//  shows the fields one at a time, which makes the same part jump.
//
//  Mapping of a woven pixel (x, s), W x 2H (774 x 504 for Tank):
//    0   : col = x,      row = s
//    CW  : col = 2H-1-s, row = x       (source top-left -> output top-right)
//    CCW : col = s,      row = W-1-x   (source top-left -> output bottom-left)
//    180 : col = W-1-x,  row = 2H-1-s  (source top-left -> output bottom-right)
//  90: consecutive lines of one field are every other byte of an output
//  row, so the last 8 source lines are kept in a line buffer and every 4th
//  line writes one 64-bit word per pixel: 4 lines of this field in
//  alternate bytes (byte enables 0x55 / 0xAA; the other field fills the
//  rest).  About 21 % write duty, through a one-line FIFO (rotate_ddr_fifo)
//  that honours DDRAM_BUSY.
//  0 / 180: a word is 8 consecutive pixels of one line (reversed for 180),
//  so an 8-pixel shift register replaces the line buffer: one word per 8
//  pixels (~11 %).
//  Triple-buffered against the scaler's FB_VBL, as screen_rotate is.  The
//  analog output is not affected.
//============================================================================

module tank_rotate #(
    parameter [6:0] MEM_BASE = 7'b0010010,  // buffers at 0x24000000, 3 x 8 MB (as screen_rotate)
    parameter       LBW      = 10           // line-buffer address bits (W <= 1024)
)(
    input  wire        clk,
    input  wire        ce,

    input  wire  [7:0] pix,         // gray level (R=G=B)
    input  wire        vs,          // active high
    input  wire        de,
    input  wire        fl,          // field flag: 1 = the field drawn half a
                                    // line lower (sampled at the VS rise)

    input  wire  [1:0] mode,        // 0 = upright, 1 = CW, 2 = CCW, 3 = 180
    output wire        video_rotated,

    output wire        FB_EN,
    output wire  [4:0] FB_FORMAT,
    output wire [11:0] FB_WIDTH,
    output wire [11:0] FB_HEIGHT,
    output wire [31:0] FB_BASE,
    output wire [13:0] FB_STRIDE,
    input  wire        FB_VBL,
    input  wire        FB_LL,

    output wire        FB_PAL_CLK,
    output wire  [7:0] FB_PAL_ADDR,
    output wire [23:0] FB_PAL_DOUT,
    output wire        FB_PAL_WR,

    output wire        DDRAM_CLK,
    input  wire        DDRAM_BUSY,
    output wire  [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,
    output wire [63:0] DDRAM_DIN,
    output wire  [7:0] DDRAM_BE,
    output wire        DDRAM_WE,
    output wire        DDRAM_RD
);

    wire rot_on = (mode == 2'd1) || (mode == 2'd2);   // 90: W/H swap
    assign video_rotated = rot_on;

    //------------------------------------------------------------------
    // Identity gray palette (index i -> RGB i,i,i), rewritten continuously
    //------------------------------------------------------------------
    reg [7:0] pal_a = 8'd0;
    always @(posedge clk) pal_a <= pal_a + 1'd1;

    assign FB_PAL_CLK  = clk;
    assign FB_PAL_ADDR = pal_a;
    assign FB_PAL_DOUT = {pal_a, pal_a, pal_a};
    assign FB_PAL_WR   = 1'b1;

    //------------------------------------------------------------------
    // Raster measurement and line / pixel counters
    //------------------------------------------------------------------
    reg        old_vs = 1'b0, old_de = 1'b0;
    reg [11:0] x = 12'd0;           // pixel index within the DE line
    reg [11:0] y = 12'd0;           // DE line index within the field
    reg [11:0] hsz_m = 12'd774;     // measured DE width of the last line
    reg [11:0] hsz = 12'd774;       // per-frame W
    reg [11:0] vsz = 12'd252;       // per-frame H (DE lines per field)
    reg        ccw = 1'b0;          // per-frame direction
    reg        rm  = 1'b1;          // per-frame row-major mode (0 or 180)
    reg        flp = 1'b0;          // per-frame 180-degree mode
    reg        ofs = 1'b0;          // this field's fl = woven row parity
    reg  [2:0] fb_en = 3'b000;

    // Geometry and mode are latched only at the start of a frame (an fl=0
    // field), so both fields in one buffer share one layout.
    always @(posedge clk) begin
        if (ce) begin
            old_vs <= vs;
            old_de <= de;
            if (de) x <= x + 1'd1;
            if (old_de & ~de) begin
                hsz_m <= x;
                x     <= 12'd0;
                y     <= y + 1'd1;
            end
            if (~old_vs & vs) begin
                y     <= 12'd0;
                ofs   <= fl;
                fb_en <= {fb_en[1:0], 1'b1};
                if (!fl) begin
                    vsz <= y;
                    hsz <= hsz_m;
                    ccw <= (mode == 2'd2);
                    rm  <= !rot_on;
                    flp <= (mode == 2'd3);
                end
            end
        end
    end

    // Stride: output width rounded up to 16 bytes (as screen_rotate), in
    // 64-bit words.  Output width = 2H (90) or W (0, 180).
    wire [11:0] vsz2     = {vsz[10:0], 1'b0};       // woven frame height 2H
    wire [11:0] fbw      = rm ? hsz : vsz2;
    wire [8:0]  stride_w = {fbw[11:4] + (|fbw[3:0]), 1'b0};
    reg  [19:0] rowmax = 20'd0;     // word offset of the last output row
    always @(posedge clk) rowmax <= ((rm ? vsz2 : hsz) - 1'd1) * stride_w;

    assign FB_EN     = fb_en[2];
    assign FB_FORMAT = 5'b00011;    // 8 bpp, palette
    assign FB_WIDTH  = fbw;
    assign FB_HEIGHT = rm ? vsz2 : hsz;
    assign FB_STRIDE = {stride_w, 3'b000};

    //------------------------------------------------------------------
    // Triple buffering (as sys screen_rotate, except that the input buffer
    // advances once per woven frame: at the VS of each fl=0 field).
    //
    // The input side is updated first, and the output side picks from the
    // new input buffer, so a frame that completes on the same clock as a
    // scaler VBL is the one the scaler takes and the two never share a
    // buffer.  The scaler runs at about twice the woven frame rate, so with
    // three buffers it moves only to a frame completed since its last move
    // (fresh); otherwise it would step back to the frame before.
    //------------------------------------------------------------------
    // the buffer that is neither a nor b (never a)
    function [1:0] buf_next;
        input [1:0] a, b;
        begin
            if (a != 2'd0 && b != 2'd0)      buf_next = 2'd0;
            else if (a != 2'd1 && b != 2'd1) buf_next = 2'd1;
            else                             buf_next = 2'd2;
        end
    endfunction

    reg [1:0] i_fb = 2'd0, o_fb = 2'd1;
    reg       fresh = 1'b0;             // a completed frame the scaler has not taken
    always @(posedge clk) begin
        reg       old_vbl, old_vs2;
        reg [1:0] i_n;
        reg       f_n;
        old_vbl <= FB_VBL;
        old_vs2 <= vs;
        i_n = i_fb;
        f_n = fresh;
        if (~old_vs2 & vs & ~fl) begin
            i_n = FB_LL ? {1'b0, ~i_fb[0]} : buf_next(i_fb, o_fb);
            f_n = 1'b1;
        end
        if (~old_vbl & FB_VBL) begin
            if (FB_LL)    o_fb <= {1'b0, ~i_n[0]};
            else if (f_n) o_fb <= buf_next(o_fb, i_n);
            f_n = 1'b0;
        end
        i_fb  <= i_n;
        fresh <= f_n;
    end

    assign FB_BASE = {MEM_BASE, o_fb, 23'd0};

    //------------------------------------------------------------------
    // Per-line group decode (stable for the whole line: y only changes at
    // the DE falling edge)
    //------------------------------------------------------------------
    // 90: the line's output column is c = 2H-1-s (CW) or s (CCW), s = 2y+ofs.
    // One field's lines land in every other byte, so a 64-bit word (8
    // columns) holds 4 of them and is flushed on the group's last line.
    wire [11:0] s      = {y[10:0], ofs};                       // woven source row
    wire [11:0] c      = vsz2 - 1'd1 - s;                      // CW output column
    wire        flush  = ccw ? ((y[1:0] == 2'd3) || (y == vsz - 1'd1))
                             : (c[2:1] == 2'd0);
    wire  [9:0] grp    = ccw ? y[11:2] : {1'b0, c[11:3]};      // 8-byte column group
    wire [19:0] addr0  = ccw ? (rowmax + grp) : {10'd0, grp};  // word offset at x = 0
    wire  [7:0] be90   = (ccw ? ofs : c[0]) ? 8'hAA : 8'h55;   // this field's bytes

    // 0 / 180: output row s / 2H-1-s (frow = its word offset: set before
    // the field's first line, then stepped two rows per line).
    // 180: output column W-1-x; a word is flushed when that column is
    // 8-aligned, i.e. it holds columns cf..cf+7 = source pixels x..x-7.  The
    // first word of a line also carries up to 7 columns past W-1 (stride
    // padding).
    // 0: output column x; a word is flushed at x = 8n+7 or at the line's
    // last pixel, and holds columns x-xl..x (xl = x mod 8), byte k = pixel
    // x-xl+k; bytes past xl are stride padding.
    reg  [19:0] frow   = 20'd0;
    always @(posedge clk)
        if (ce) begin
            if (old_de & ~de)           frow <= flp ? frow - {stride_w, 1'b0}
                                                    : frow + {stride_w, 1'b0};
            else if (y == 12'd0 && !de) frow <= flp ? rowmax - (ofs ? stride_w : 9'd0)
                                                    : (ofs ? stride_w : 9'd0);
        end
    wire [11:0] cf     = hsz - 1'd1 - x;
    wire        fflush = flp ? (cf[2:0] == 3'd0)
                             : ((x[2:0] == 3'd7) || (x == hsz - 1'd1));
    wire [19:0] faddr  = frow + (flp ? cf[11:3] : x[11:3]);
    reg  [55:0] fsr    = 56'd0;     // the previous 7 pixels of this line
    always @(posedge clk) if (ce && de) fsr <= {fsr[47:0], pix};

    //------------------------------------------------------------------
    // 8-line buffer: slot y[2:0] is written at x; all slots read at x
    //------------------------------------------------------------------
    wire [7:0] lb_q [0:7];
    genvar j;
    generate
        for (j = 0; j < 8; j = j + 1) begin : g_lb
            reg [7:0] mem [0:(1<<LBW)-1];
            reg [7:0] q;
            always @(posedge clk) begin
                if (ce && de && (y[2:0] == j)) mem[x[LBW-1:0]] <= pix;
                q <= mem[x[LBW-1:0]];
            end
            assign lb_q[j] = q;
        end
    endgenerate

    //------------------------------------------------------------------
    // Stage 0: address walk; stage 1: assemble the 8-pixel word
    //------------------------------------------------------------------
    reg  [19:0] waddr_next = 20'd0;
    wire [19:0] waddr = (x == 12'd0) ? addr0 : waddr_next;

    reg         s1_valid = 1'b0;
    reg  [19:0] s1_addr;
    reg   [1:0] s1_fb;
    reg   [7:0] s1_pix;
    reg   [2:0] s1_slot;
    reg         s1_ccw;
    reg         s1_rm;
    reg         s1_flp;
    reg   [2:0] s1_xl;
    reg   [7:0] s1_be;
    reg  [63:0] s1_fword;

    always @(posedge clk) begin
        s1_valid <= 1'b0;
        if (ce && de) begin
            waddr_next <= ccw ? (waddr - stride_w) : (waddr + stride_w);
            s1_valid   <= (rm ? fflush : flush) & fb_en[0];
            s1_addr    <= rm ? faddr : waddr;
            s1_fb      <= i_fb;
            s1_pix     <= pix;
            s1_slot    <= y[2:0];
            s1_ccw     <= ccw;
            s1_rm      <= rm;
            s1_flp     <= flp;
            s1_xl      <= x[2:0];
            s1_be      <= rm ? 8'hFF : be90;
            s1_fword   <= {fsr, pix};   // byte k = source pixel x-k
        end
    end

    // byte k of the word = output column (group*8 + k); only this field's
    // bytes are enabled (s1_be), and those hold its lines k/2 apart:
    //   CW : field line y - k/2      -> slot (y - k/2) mod 8  (k/2 = 0 is live)
    //   CCW: field line 4g + k/2     -> slot {y[2], k/2}      (k/2 = y[1:0] live)
    // 0: byte k = s1_fword byte xl-k (source pixel x-xl+k).
    wire [63:0] rword, uword;
    wire [63:0] word = s1_rm ? (s1_flp ? s1_fword : uword) : rword;
    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : g_asm
            wire [1:0] bh = b >> 1;
            wire [2:0] sl = s1_ccw ? {s1_slot[2], bh} : (s1_slot - {1'b0, bh});
            localparam [2:0] B3 = b;
            wire [2:0] ub = s1_xl - B3;
            assign rword[b*8 +: 8] = (sl == s1_slot) ? s1_pix : lb_q[sl];
            assign uword[b*8 +: 8] = s1_fword[ub*8 +: 8];
        end
    endgenerate

    //------------------------------------------------------------------
    // DDR write FIFO (honours DDRAM_BUSY)
    //------------------------------------------------------------------
    assign DDRAM_CLK      = clk;
    assign DDRAM_BURSTCNT = 8'd1;
    assign DDRAM_RD       = 1'b0;

    rotate_ddr_fifo u_fifo (
        .clk      (clk),
        .in_addr  ({MEM_BASE, s1_fb, s1_addr}),
        .in_din   (word),
        .in_be    (s1_be),
        .in_we    (s1_valid),
        .ddr_busy (DDRAM_BUSY),
        .ddr_addr (DDRAM_ADDR),
        .ddr_din  (DDRAM_DIN),
        .ddr_be   (DDRAM_BE),
        .ddr_we   (DDRAM_WE),
        .overflow ()                // sticky overflow flag (unused)
    );

endmodule
