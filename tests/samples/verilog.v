// A counter.
module counter (
    input wire clk,
    input wire reset,
    output reg [7:0] count
);
  /* count up */
  always @(posedge clk) begin
    if (reset) count <= 8'd0;
    else count <= count + 1;
  end
  initial $display("ready");
endmodule
