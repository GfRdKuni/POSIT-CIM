`timescale 1ns/1ps
module exponent_adder #(
    parameter DATA_WIDTH = 8 ,
    parameter LANE_WIDTH = 16,
    parameter IDLE       = 0 ,
    parameter BUSY       = 1
)
(
    input  wire                             clk_333MHz_i,
    input  wire                             rst_n_i     ,
    input  wire                             data_vld_i  ,
    input  wire                             data_rdy_i  ,
    input  wire [DATA_WIDTH*LANE_WIDTH-1:0] w_exp_i     ,
    input  wire [DATA_WIDTH*LANE_WIDTH-1:0] a_exp_i     ,
    output wire                             data_vld_o  ,
	output wire [DATA_WIDTH*LANE_WIDTH-1:0] result_exp_o,
	output wire                             data_rdy_o   
);
    reg [DATA_WIDTH*LANE_WIDTH-1:0] w_exp, a_exp;
    reg                                    state;

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            state <= IDLE;
        end
        else if (data_vld_i && data_rdy_o & (state == IDLE)) begin
            state <= BUSY;
        end
        else if (data_vld_o && data_rdy_i & (state == BUSY)) begin
            state <= IDLE;
        end
        else begin
            state <= state;
        end
    end

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            w_exp <= 0;
            a_exp <= 0;
        end
        else if (data_vld_i && data_rdy_o & (state == IDLE)) begin
            w_exp <= w_exp_i;
            a_exp <= a_exp_i;
        end
        else begin
            w_exp <= w_exp;
            a_exp <= a_exp;
        end
    end

    wire signed [DATA_WIDTH-1:0] w_exp_lane0, w_exp_lane1, w_exp_lane2, w_exp_lane3, w_exp_lane4, w_exp_lane5, w_exp_lane6, w_exp_lane7, w_exp_lane8, w_exp_lane9, w_exp_lane10, w_exp_lane11, w_exp_lane12, w_exp_lane13, w_exp_lane14, w_exp_lane15;
    wire signed [DATA_WIDTH-1:0] a_exp_lane0, a_exp_lane1, a_exp_lane2, a_exp_lane3, a_exp_lane4, a_exp_lane5, a_exp_lane6, a_exp_lane7, a_exp_lane8, a_exp_lane9, a_exp_lane10, a_exp_lane11, a_exp_lane12, a_exp_lane13, a_exp_lane14, a_exp_lane15;
    assign w_exp_lane0 = w_exp[DATA_WIDTH-1:0];
    assign w_exp_lane1 = w_exp[2*DATA_WIDTH-1:DATA_WIDTH];
    assign w_exp_lane2 = w_exp[3*DATA_WIDTH-1:2*DATA_WIDTH];
    assign w_exp_lane3 = w_exp[4*DATA_WIDTH-1:3*DATA_WIDTH];
    assign w_exp_lane4 = w_exp[5*DATA_WIDTH-1:4*DATA_WIDTH];
    assign w_exp_lane5 = w_exp[6*DATA_WIDTH-1:5*DATA_WIDTH];
    assign w_exp_lane6 = w_exp[7*DATA_WIDTH-1:6*DATA_WIDTH];
    assign w_exp_lane7 = w_exp[8*DATA_WIDTH-1:7*DATA_WIDTH];
    assign w_exp_lane8 = w_exp[9*DATA_WIDTH-1:8*DATA_WIDTH];
    assign w_exp_lane9 = w_exp[10*DATA_WIDTH-1:9*DATA_WIDTH];
    assign w_exp_lane10 = w_exp[11*DATA_WIDTH-1:10*DATA_WIDTH];
    assign w_exp_lane11 = w_exp[12*DATA_WIDTH-1:11*DATA_WIDTH];
    assign w_exp_lane12 = w_exp[13*DATA_WIDTH-1:12*DATA_WIDTH];
    assign w_exp_lane13 = w_exp[14*DATA_WIDTH-1:13*DATA_WIDTH];
    assign w_exp_lane14 = w_exp[15*DATA_WIDTH-1:14*DATA_WIDTH];
    assign w_exp_lane15 = w_exp[16*DATA_WIDTH-1:15*DATA_WIDTH];
    assign a_exp_lane0 = a_exp[DATA_WIDTH-1:0];
    assign a_exp_lane1 = a_exp[2*DATA_WIDTH-1:DATA_WIDTH];
    assign a_exp_lane2 = a_exp[3*DATA_WIDTH-1:2*DATA_WIDTH];
    assign a_exp_lane3 = a_exp[4*DATA_WIDTH-1:3*DATA_WIDTH]; 
    assign a_exp_lane4 = a_exp[5*DATA_WIDTH-1:4*DATA_WIDTH];
    assign a_exp_lane5 = a_exp[6*DATA_WIDTH-1:5*DATA_WIDTH];
    assign a_exp_lane6 = a_exp[7*DATA_WIDTH-1:6*DATA_WIDTH];
    assign a_exp_lane7 = a_exp[8*DATA_WIDTH-1:7*DATA_WIDTH];
    assign a_exp_lane8 = a_exp[9*DATA_WIDTH-1:8*DATA_WIDTH];
    assign a_exp_lane9 = a_exp[10*DATA_WIDTH-1:9*DATA_WIDTH];
    assign a_exp_lane10 = a_exp[11*DATA_WIDTH-1:10*DATA_WIDTH];
    assign a_exp_lane11 = a_exp[12*DATA_WIDTH-1:11*DATA_WIDTH];
    assign a_exp_lane12 = a_exp[13*DATA_WIDTH-1:12*DATA_WIDTH];
    assign a_exp_lane13 = a_exp[14*DATA_WIDTH-1:13*DATA_WIDTH];
    assign a_exp_lane14 = a_exp[15*DATA_WIDTH-1:14*DATA_WIDTH];
    assign a_exp_lane15 = a_exp[16*DATA_WIDTH-1:15*DATA_WIDTH];
    assign result_exp_o[DATA_WIDTH-1:0] = w_exp_lane0 + a_exp_lane0;
    assign result_exp_o[2*DATA_WIDTH-1:DATA_WIDTH] = w_exp_lane1 + a_exp_lane1;
    assign result_exp_o[3*DATA_WIDTH-1:2*DATA_WIDTH] = w_exp_lane2 + a_exp_lane2;
    assign result_exp_o[4*DATA_WIDTH-1:3*DATA_WIDTH] = w_exp_lane3 + a_exp_lane3;
    assign result_exp_o[5*DATA_WIDTH-1:4*DATA_WIDTH] = w_exp_lane4 + a_exp_lane4;
    assign result_exp_o[6*DATA_WIDTH-1:5*DATA_WIDTH] = w_exp_lane5 + a_exp_lane5;
    assign result_exp_o[7*DATA_WIDTH-1:6*DATA_WIDTH] = w_exp_lane6 + a_exp_lane6;
    assign result_exp_o[8*DATA_WIDTH-1:7*DATA_WIDTH] = w_exp_lane7 + a_exp_lane7;
    assign result_exp_o[9*DATA_WIDTH-1:8*DATA_WIDTH] = w_exp_lane8 + a_exp_lane8;
    assign result_exp_o[10*DATA_WIDTH-1:9*DATA_WIDTH] = w_exp_lane9 + a_exp_lane9;
    assign result_exp_o[11*DATA_WIDTH-1:10*DATA_WIDTH] = w_exp_lane10 + a_exp_lane10;
    assign result_exp_o[12*DATA_WIDTH-1:11*DATA_WIDTH] = w_exp_lane11 + a_exp_lane11;
    assign result_exp_o[13*DATA_WIDTH-1:12*DATA_WIDTH] = w_exp_lane12 + a_exp_lane12;
    assign result_exp_o[14*DATA_WIDTH-1:13*DATA_WIDTH] = w_exp_lane13 + a_exp_lane13;
    assign result_exp_o[15*DATA_WIDTH-1:14*DATA_WIDTH] = w_exp_lane14 + a_exp_lane14;
    assign result_exp_o[16*DATA_WIDTH-1:15*DATA_WIDTH] = w_exp_lane15 + a_exp_lane15;


    assign data_vld_o = (state == BUSY);
    assign data_rdy_o = (state == IDLE);




endmodule