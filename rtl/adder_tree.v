`timescale 1ns/1ps
module adder_tree #(
    parameter EXPONENT_WIDTH = 8,
    parameter FRACTION_WIDTH = 28,
    parameter LANE_WIDTH = 16,
    parameter RESULT_WIDTH = 32
)
(
    input  wire                                 clk_333MHz_i   ,
    input  wire                                 rst_n_i        ,
    input  wire                                 exp_data_vld_i ,
    input  wire                                 frac_data_vld_i,
    input  wire [EXPONENT_WIDTH*LANE_WIDTH-1:0] delta_exp_i    ,
    input  wire [EXPONENT_WIDTH-1:0]            max_exp_i      ,
    input  wire [FRACTION_WIDTH*LANE_WIDTH-1:0] frac_i         ,
    input  wire                                 data_rdy_i     , 
    output wire [RESULT_WIDTH-1:0]              frac_result_o  ,
    output wire [EXPONENT_WIDTH-1:0]            exp_result_o   ,
    output wire                                 result_vld_o   ,
    output wire                                 exp_data_rdy_o ,
    output wire                                 frac_data_rdy_o
);

    // ────── 状态定义 ──────
    localparam IDLE      = 3'b000,
               WAIT_FRAC = 3'b001,   // 已收 exp，等 frac
               WAIT_EXP  = 3'b010,   // 已收 frac，等 exp
               CALC      = 3'b011,   // 两路已锁存，计算中
               DONE      = 3'b100;   // 结果有效

    reg [2:0] state, next_state;

    // ────── 锁存寄存器 ──────
    reg [EXPONENT_WIDTH*LANE_WIDTH-1:0] delta_reg;
    reg [EXPONENT_WIDTH-1:0]            max_reg;
    reg [FRACTION_WIDTH*LANE_WIDTH-1:0] frac_reg;

    // ────── 状态机 ──────
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i)
            state <= IDLE;
        else
            state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (exp_data_vld_i && exp_data_rdy_o) begin
                    if (frac_data_vld_i && frac_data_rdy_o)
                        next_state = CALC;          // 两路同时到达
                    else
                        next_state = WAIT_FRAC;     // 先收 exp
                end else if (frac_data_vld_i && frac_data_rdy_o) begin
                    next_state = WAIT_EXP;          // 先收 frac
                end else begin
                    next_state = IDLE;
                end
            end
            WAIT_FRAC: begin
                if (frac_data_vld_i && frac_data_rdy_o)
                    next_state = CALC;
                else
                    next_state = WAIT_FRAC;
            end
            WAIT_EXP: begin
                if (exp_data_vld_i && exp_data_rdy_o)
                    next_state = CALC;
                else
                    next_state = WAIT_EXP;
            end
            CALC: begin
                next_state = DONE;                  // 一拍后输出
            end
            DONE: begin
                if (result_vld_o && data_rdy_i)
                    next_state = IDLE;
                else
                    next_state = DONE;
            end
            default: next_state = IDLE;
        endcase
    end

    // ────── 握手 ready 信号（组合） ──────
    assign exp_data_rdy_o  = (state == IDLE) || (state == WAIT_EXP);
    assign frac_data_rdy_o = (state == IDLE) || (state == WAIT_FRAC);

    // ────── 数据锁存（时序） ──────
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            delta_reg <= 0;
            max_reg   <= 0;
        end else if ((state == IDLE   && exp_data_vld_i && exp_data_rdy_o) ||
                     (state == WAIT_EXP && exp_data_vld_i && exp_data_rdy_o)) begin
            delta_reg <= delta_exp_i;
            max_reg   <= max_exp_i;
        end else begin
            delta_reg <= delta_reg;
            max_reg   <= max_reg;
        end
    end

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            frac_reg <= 0;
        end else if ((state == IDLE      && frac_data_vld_i && frac_data_rdy_o) ||
                     (state == WAIT_FRAC && frac_data_vld_i && frac_data_rdy_o)) begin
            frac_reg <= frac_i;
        end else begin
            frac_reg <= frac_reg;
        end
    end

    // ────── 抽取各 lane 的 delta 和 fraction（单维线网） ──────
    wire signed [7:0] d0;  assign d0  = delta_reg[1*8-1 : 0*8];
    wire signed [7:0] d1;  assign d1  = delta_reg[2*8-1 : 1*8];
    wire signed [7:0] d2;  assign d2  = delta_reg[3*8-1 : 2*8];
    wire signed [7:0] d3;  assign d3  = delta_reg[4*8-1 : 3*8];
    wire signed [7:0] d4;  assign d4  = delta_reg[5*8-1 : 4*8];
    wire signed [7:0] d5;  assign d5  = delta_reg[6*8-1 : 5*8];
    wire signed [7:0] d6;  assign d6  = delta_reg[7*8-1 : 6*8];
    wire signed [7:0] d7;  assign d7  = delta_reg[8*8-1 : 7*8];
    wire signed [7:0] d8;  assign d8  = delta_reg[9*8-1 : 8*8];
    wire signed [7:0] d9;  assign d9  = delta_reg[10*8-1 : 9*8];
    wire signed [7:0] d10; assign d10 = delta_reg[11*8-1 : 10*8];
    wire signed [7:0] d11; assign d11 = delta_reg[12*8-1 : 11*8];
    wire signed [7:0] d12; assign d12 = delta_reg[13*8-1 : 12*8];
    wire signed [7:0] d13; assign d13 = delta_reg[14*8-1 : 13*8];
    wire signed [7:0] d14; assign d14 = delta_reg[15*8-1 : 14*8];
    wire signed [7:0] d15; assign d15 = delta_reg[16*8-1 : 15*8];

    wire signed [27:0] f0;  assign f0  = frac_reg[1*28-1 : 0*28];
    wire signed [27:0] f1;  assign f1  = frac_reg[2*28-1 : 1*28];
    wire signed [27:0] f2;  assign f2  = frac_reg[3*28-1 : 2*28];
    wire signed [27:0] f3;  assign f3  = frac_reg[4*28-1 : 3*28];
    wire signed [27:0] f4;  assign f4  = frac_reg[5*28-1 : 4*28];
    wire signed [27:0] f5;  assign f5  = frac_reg[6*28-1 : 5*28];
    wire signed [27:0] f6;  assign f6  = frac_reg[7*28-1 : 6*28];
    wire signed [27:0] f7;  assign f7  = frac_reg[8*28-1 : 7*28];
    wire signed [27:0] f8;  assign f8  = frac_reg[9*28-1 : 8*28];
    wire signed [27:0] f9;  assign f9  = frac_reg[10*28-1 : 9*28];
    wire signed [27:0] f10; assign f10 = frac_reg[11*28-1 : 10*28];
    wire signed [27:0] f11; assign f11 = frac_reg[12*28-1 : 11*28];
    wire signed [27:0] f12; assign f12 = frac_reg[13*28-1 : 12*28];
    wire signed [27:0] f13; assign f13 = frac_reg[14*28-1 : 13*28];
    wire signed [27:0] f14; assign f14 = frac_reg[15*28-1 : 14*28];
    wire signed [27:0] f15; assign f15 = frac_reg[16*28-1 : 15*28];

    // ────── 尾数对齐移位（有符号算术右移），并扩展至 32 位 ──────
    wire signed [31:0] s0;  assign s0  = (d0  >= 28) ? (f0[27] ? 32'hFFFFFFFF : 32'h00000000) : (f0  >>> d0);
    wire signed [31:0] s1;  assign s1  = (d1  >= 28) ? (f1[27] ? 32'hFFFFFFFF : 32'h00000000) : (f1  >>> d1);
    wire signed [31:0] s2;  assign s2  = (d2  >= 28) ? (f2[27] ? 32'hFFFFFFFF : 32'h00000000) : (f2  >>> d2);
    wire signed [31:0] s3;  assign s3  = (d3  >= 28) ? (f3[27] ? 32'hFFFFFFFF : 32'h00000000) : (f3  >>> d3);
    wire signed [31:0] s4;  assign s4  = (d4  >= 28) ? (f4[27] ? 32'hFFFFFFFF : 32'h00000000) : (f4  >>> d4);
    wire signed [31:0] s5;  assign s5  = (d5  >= 28) ? (f5[27] ? 32'hFFFFFFFF : 32'h00000000) : (f5  >>> d5);
    wire signed [31:0] s6;  assign s6  = (d6  >= 28) ? (f6[27] ? 32'hFFFFFFFF : 32'h00000000) : (f6  >>> d6);
    wire signed [31:0] s7;  assign s7  = (d7  >= 28) ? (f7[27] ? 32'hFFFFFFFF : 32'h00000000) : (f7  >>> d7);
    wire signed [31:0] s8;  assign s8  = (d8  >= 28) ? (f8[27] ? 32'hFFFFFFFF : 32'h00000000) : (f8  >>> d8);
    wire signed [31:0] s9;  assign s9  = (d9  >= 28) ? (f9[27] ? 32'hFFFFFFFF : 32'h00000000) : (f9  >>> d9);
    wire signed [31:0] s10; assign s10 = (d10 >= 28) ? (f10[27]? 32'hFFFFFFFF : 32'h00000000) : (f10 >>> d10);
    wire signed [31:0] s11; assign s11 = (d11 >= 28) ? (f11[27]? 32'hFFFFFFFF : 32'h00000000) : (f11 >>> d11);
    wire signed [31:0] s12; assign s12 = (d12 >= 28) ? (f12[27]? 32'hFFFFFFFF : 32'h00000000) : (f12 >>> d12);
    wire signed [31:0] s13; assign s13 = (d13 >= 28) ? (f13[27]? 32'hFFFFFFFF : 32'h00000000) : (f13 >>> d13);
    wire signed [31:0] s14; assign s14 = (d14 >= 28) ? (f14[27]? 32'hFFFFFFFF : 32'h00000000) : (f14 >>> d14);
    wire signed [31:0] s15; assign s15 = (d15 >= 28) ? (f15[27]? 32'hFFFFFFFF : 32'h00000000) : (f15 >>> d15);

    // ────── 加法树（两级分组：4 组 × 4 个，再汇总） ──────
    wire signed [31:0] sum_g0, sum_g1, sum_g2, sum_g3;
    assign sum_g0 = s0 + s1 + s2 + s3;
    assign sum_g1 = s4 + s5 + s6 + s7;
    assign sum_g2 = s8 + s9 + s10 + s11;
    assign sum_g3 = s12 + s13 + s14 + s15;
    wire signed [31:0] sum_total;
    assign sum_total = sum_g0 + sum_g1 + sum_g2 + sum_g3;

    // ────── 最终输出 ──────
    assign frac_result_o = sum_total;
    assign exp_result_o  = max_reg;          // 直接输出最大指数，后续归一化由编码单元完成
    assign result_vld_o  = (state == DONE);

endmodule