`timescale 1ns/1ps
module tb_max_exp;
reg clk=0; always #5 clk=~clk;
reg rst=0,valid=0,ready=0;
reg [127:0] data=0;
wire valid_o,ready_o;
wire [7:0] maximum;
wire [127:0] delta;
reg [263:0] vectors[0:511];
integer i,j;
tc_bwc_mf dut(.clk_333MHz_i(clk),.rst_n_i(rst),.data_vld_i(valid),.data_rdy_i(ready),.data_i(data),.data_vld_o(valid_o),.data_rdy_o(ready_o),.max_exp_o(maximum),.delta_exp_o(delta));
initial begin
 $readmemh("max_vectors.hex",vectors);
 for(i=0;i<512;i=i+1)
  if((^vectors[i])===1'bx) $fatal(1,"missing or unknown maximum vector %0d",i);
 repeat(3) @(negedge clk); rst=1;
 for(i=0;i<512;i=i+1) begin
  wait(ready_o); @(negedge clk); data=vectors[i][263:136]; valid=1;
  @(negedge clk); valid=0; data=~data;
  wait(valid_o);
  repeat(i%4+1) begin
   @(negedge clk);
   if(valid_o!==1'b1 || maximum!==vectors[i][135:128] || delta!==vectors[i][127:0]) $fatal(1,"max/delta/stall mismatch vector%0d",i);
  end
  ready=1; @(negedge clk); ready=0;
 end
 $display("PASS:512 signed16lane maximum/delta vectors with output stalls");$finish;
end
initial begin #200000; $fatal(1,"maximum timeout");end
endmodule
