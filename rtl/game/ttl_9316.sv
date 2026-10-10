//============================================================================
// TTL 9316 - 4-bit synchronous binary counter
//============================================================================
// Logical model of the presettable counter used throughout Tank.
// q[0] is QA and q[3] is QD. clear and load are active-low.
// clear is asynchronous and dominant; load is synchronous and dominates count.
// rc is the ripple-carry output used to cascade counter stages.
//============================================================================

module ttl_9316 (
    input  wire       clk,
    input  wire       clr_n,
    input  wire       load_n,
    input  wire       enp,
    input  wire       ent,
    input  wire [3:0] d,
    output reg  [3:0] q  = 4'd0,
    output wire       rc
);

    always @(posedge clk or negedge clr_n) begin
        if (!clr_n) begin
            q <= 4'd0;
        end else if (!load_n) begin
            q <= d;
        end else if (enp && ent) begin
            q <= q + 4'd1;
        end
    end

    assign rc = ent & &q;

endmodule
