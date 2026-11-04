`timescale 1ns/1ps
module tb_exponent_add;
reg clk=0;always #5 clk=~clk;
reg rst=0,valid=0,ready=0;
reg [127:0] a=0,w=0;
wire v,r;
wire [127:0] result;
reg [383:0] vectors[0:511];
integer i;
exponent_adder dut(.clk_333MHz_i(clk),.rst_n_i(rst),.data_vld_i(valid),.data_rdy_i(ready),.a_exp_i(a),.w_exp_i(w),.data_vld_o(v),.data_rdy_o(r),.result_exp_o(result));
initial begin
 $readmemh("add_vectors.hex",vectors);
 for(i=0;i<512;i=i+1)
  if((^vectors[i])===1'bx) $fatal(1,"missing or unknown addition vector %0d",i);
 repeat(3) @(negedge clk);rst=1;
 for(i=0;i<512;i=i+1)begin
  wait(r);@(negedge clk);a=vectors[i][383:256];w=vectors[i][255:128];valid=1;
  @(negedge clk);valid=0;a=0;w=0;wait(v);
  repeat(i%3+1)begin @(negedge clk);if(v!==1'b1 || result!==vectors[i][127:0])$fatal(1,"sum/stall mismatch%0d",i);end
  ready=1;@(negedge clk);ready=0;
 end
 $display("PASS:512 exponent-add vectors,8192 signed modular lane sums");$finish;
end
initial begin #100000;$fatal(1,"adder timeout");end
endmodule
