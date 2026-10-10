//============================================================================
//  rotate_ddr_fifo - show-ahead write FIFO in front of the emu DDRAM port
//
//  Decouples tank_rotate's framebuffer writes from DDR3 waitrequest
//  (DDRAM_BUSY).  In 90-degree modes tank_rotate emits one 64-bit word per
//  pixel clock, but only on every 4th source line (774 words, then ~3 idle
//  lines), so the FIFO is one full line deep: a whole flush line can be
//  accepted even if the port stalls throughout it, and drains during the
//  following lines.
//  While BUSY is high the head entry is held on WE/ADDR/DIN/BE, as Avalon
//  requires.  Memory read is registered so Quartus maps it to M10K.
//============================================================================

module rotate_ddr_fifo #(
    parameter AW = 10                    // 2^AW entries (1024 >= one 774-px line)
)(
    input  wire        clk,

    input  wire [28:0] in_addr,
    input  wire [63:0] in_din,
    input  wire  [7:0] in_be,
    input  wire        in_we,

    input  wire        ddr_busy,
    output wire [28:0] ddr_addr,
    output wire [63:0] ddr_din,
    output wire  [7:0] ddr_be,
    output wire        ddr_we,

    output reg         overflow = 1'b0  // sticky: a write was dropped (FIFO full)
);

    localparam DW = 29 + 64 + 8;

    reg [DW-1:0] mem [0:(1<<AW)-1];
    reg   [AW:0] wptr = 0;
    reg   [AW:0] rptr = 0;

    reg [DW-1:0] head;
    reg          head_valid = 1'b0;

    wire mem_empty = (wptr == rptr);
    wire mem_full  = (wptr == {~rptr[AW], rptr[AW-1:0]});
    wire pop       = head_valid & ~ddr_busy;
    wire mem_rd    = ~mem_empty & (~head_valid | pop);

    always @(posedge clk) begin
        if (in_we) begin
            if (!mem_full) begin
                mem[wptr[AW-1:0]] <= {in_addr, in_din, in_be};
                wptr <= wptr + 1'd1;
            end else
                overflow <= 1'b1;
        end

        if (mem_rd) begin
            head <= mem[rptr[AW-1:0]];
            rptr <= rptr + 1'd1;
        end

        if (mem_rd)   head_valid <= 1'b1;
        else if (pop) head_valid <= 1'b0;
    end

    assign ddr_we   = head_valid;
    assign ddr_addr = head[DW-1:72];
    assign ddr_din  = head[71:8];
    assign ddr_be   = head[7:0];

endmodule
