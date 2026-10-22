`timescale 1ns/1ps
module encode_collect#(
    parameter LANE_LENGTH = 16
)
(
    input  wire                                 clk_333MHz_i ,
    input  wire                                 rst_n        ,
    input  wire [LANE_LENGTH-1:0]               data_vld_i   ,
    input  wire [4*LANE_LENGTH-1:0]             is_zero_i    ,
    input  wire [LANE_LENGTH-1:0]               data_rdy_i   ,
    output wire [LANE_LENGTH-1:0]               data_rdy_o   ,
    output wire [2:0]                           cyc_avg_o    ,
    output wire                                 start_o      , 
);
    


endmodule