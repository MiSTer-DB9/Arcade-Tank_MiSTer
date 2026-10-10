//============================================================================
// Tank - the 2 KB ROM (90-2006), as a dual-port RAM loaded from the MRA
//============================================================================
// Port A: write, from the MiSTer ROM download (ioctl).
// Port B: read, by the core (one clock of latency).
// Both ports run on the pixel clock; Quartus maps it to block RAM.
//============================================================================

module dpram_2k8 (
    // Port A: write (ROM download)
    input  wire        clk_a,
    input  wire        wr_a,
    input  wire [10:0] addr_a,
    input  wire [7:0]  din_a,

    // Port B: read
    input  wire        clk_b,
    input  wire [10:0] addr_b,
    output reg  [7:0]  dout_b
);

    (* ramstyle = "no_rw_check" *) reg [7:0] ram [0:2047];

    // Port A: synchronous write
    always @(posedge clk_a) begin
        if (wr_a) begin
            ram[addr_a] <= din_a;
        end
    end

    // Port B: synchronous read (one-cycle latency)
    always @(posedge clk_b) begin
        dout_b <= ram[addr_b];
    end

endmodule
