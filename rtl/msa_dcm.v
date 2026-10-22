`timescale 1ns/1ps
module msa_dcm #(
    parameter DATA_WIDTH = 14,
    parameter IDLE       = 2'b00,
    parameter WAIT_WGT   = 2'b01,   // 激活已到，等待权重
    parameter WAIT_ACT   = 2'b10,   // 权重已到，等待激活
    parameter CALCULATE  = 2'b11
)
(
    input  wire                           clk_333MHz_i    ,
    input  wire                           rst_n_i         ,
    // 激活路径（被乘数）
    input  wire        [DATA_WIDTH-1:0]   a_frac_i        ,
    input  wire        [DATA_WIDTH-1:0]   a_frac_ix2      ,
    input  wire        [DATA_WIDTH-1:0]   a_frac_i_minus  ,
    input  wire        [DATA_WIDTH-1:0]   a_frac_ix2_minus,
    input  wire                           data_vld_act_i  ,
    output wire                           data_rdy_act_o  ,
    // 权重路径（Booth 编码后的 PP 等）
    input  wire signed [2:0]              PP6_i           ,
    input  wire signed [2:0]              PP5_i           ,
    input  wire signed [2:0]              PP4_i           ,
    input  wire signed [2:0]              PP3_i           ,
    input  wire signed [2:0]              PP2_i           ,
    input  wire signed [2:0]              PP1_i           ,
    input  wire signed [2:0]              PP0_i           ,
    input  wire        [2:0]              cyc_avg_i       ,
    input  wire        [3:0]              is_zero_i       ,
    input  wire                           data_vld_wgt_i  ,
    output wire                           data_rdy_wgt_o  ,
    // 下游握手
    input  wire                           data_rdy_i      ,
    output wire        [DATA_WIDTH*2-1:0] result_frac_o   ,
    output wire                           data_vld_o
);

reg signed [DATA_WIDTH*2-1:0] result_frac        ;
reg        [2:0]              cyc_cnt            ;
reg        [1:0]              state              ;   // 2‑bit 状态
reg        [DATA_WIDTH-1:0]   a_frac             ;
reg        [DATA_WIDTH-1:0]   a_fracx2           ;
reg        [DATA_WIDTH-1:0]   a_frac_minus       ;
reg        [DATA_WIDTH-1:0]   a_fracx2_minus     ;
reg        [2:0]              PP6                ;
reg        [2:0]              PP5                ;
reg        [2:0]              PP4                ;
reg        [2:0]              PP3                ;
reg        [2:0]              PP2                ;
reg        [2:0]              PP1                ;
reg        [2:0]              PP0                ;
reg        [2:0]              cyc_avg            ;
reg        [3:0]              is_zero            ;
reg        [1:0]              proc_position      ;
reg signed [DATA_WIDTH*2-1:0] partial_product    ;
reg signed [DATA_WIDTH*2-1:0] PP6_partial_product;
reg signed [DATA_WIDTH*2-1:0] PP5_partial_product;
reg signed [DATA_WIDTH*2-1:0] PP4_partial_product;
reg signed [DATA_WIDTH*2-1:0] PP3_partial_product;
reg signed [DATA_WIDTH*2-1:0] PP2_partial_product;
reg signed [DATA_WIDTH*2-1:0] PP1_partial_product;
reg signed [DATA_WIDTH*2-1:0] PP0_partial_product;

// ────── 状态机（双路径会合） ──────
always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        state <= IDLE;
    end
    else begin
        case (state)
            IDLE: begin
                if (data_vld_act_i & data_rdy_act_o) begin
                    // 激活数据先到
                    if (data_vld_wgt_i & data_rdy_wgt_o)
                        state <= CALCULATE;    // 两路同时到（或权重已锁存）
                    else
                        state <= WAIT_WGT;      // 只有激活，等权重
                end
                else if (data_vld_wgt_i & data_rdy_wgt_o) begin
                    // 权重数据先到，激活未到
                    state <= WAIT_ACT;
                end
            end

            WAIT_WGT: begin
                if (data_vld_wgt_i & data_rdy_wgt_o)
                    state <= CALCULATE;
            end

            WAIT_ACT: begin
                if (data_vld_act_i & data_rdy_act_o)
                    state <= CALCULATE;
            end

            CALCULATE: begin
                if (data_vld_o & data_rdy_i)
                    state <= IDLE;
            end

            default: state <= IDLE;
        endcase
    end
end

// ────── 独立握手 ready 信号 ──────
assign data_rdy_act_o = (state == IDLE) || (state == WAIT_ACT);
assign data_rdy_wgt_o = (state == IDLE) || (state == WAIT_WGT);

// ────── cyc_cnt / result_frac 控制 ──────
always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        cyc_cnt <= 0;
    end
    else if (state == CALCULATE) begin
        if (data_vld_o & data_rdy_i)
            cyc_cnt <= 0;
        else if (~data_vld_o)
            cyc_cnt <= cyc_cnt + 1;
    end
    else begin
        cyc_cnt <= 0;
    end
end

always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        result_frac <= 0;
    end
    else if (state == CALCULATE) begin
        if (data_vld_o & data_rdy_i)
            result_frac <= 0;         // 计算结果已被取走，清零准备下次
        else if (~data_vld_o)
            result_frac <= result_frac + partial_product;
    end
    else begin
        result_frac <= 0;
    end
end

// ────── 激活数据锁存（仅当握手成功） ──────
always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        a_frac         <= 0;
        a_fracx2       <= 0;
        a_frac_minus   <= 0;
        a_fracx2_minus <= 0;
    end
    else if (data_vld_act_i & data_rdy_act_o) begin
        a_frac         <= a_frac_i;
        a_fracx2       <= a_frac_ix2;
        a_frac_minus   <= a_frac_i_minus;
        a_fracx2_minus <= a_frac_ix2_minus;
    end
    else begin
        a_frac         <= a_frac;
        a_fracx2       <= a_fracx2;
        a_frac_minus   <= a_frac_minus;
        a_fracx2_minus <= a_fracx2_minus;
    end
end

// ────── 权重数据锁存（仅当握手成功） ──────
always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        PP6     <= 0;
        PP5     <= 0;
        PP4     <= 0;
        PP3     <= 0;
        PP2     <= 0;
        PP1     <= 0;
        PP0     <= 0;
        cyc_avg <= 0;
        is_zero <= 0;
    end
    else if (data_vld_wgt_i & data_rdy_wgt_o) begin
        PP6     <= PP6_i;
        PP5     <= PP5_i;
        PP4     <= PP4_i;
        PP3     <= PP3_i;
        PP2     <= PP2_i;
        PP1     <= PP1_i;
        PP0     <= PP0_i;
        cyc_avg <= cyc_avg_i;
        is_zero <= is_zero_i;
    end
    else begin
        PP6     <= PP6;
        PP5     <= PP5;
        PP4     <= PP4;
        PP3     <= PP3;
        PP2     <= PP2;
        PP1     <= PP1;
        PP0     <= PP0;
        cyc_avg <= cyc_avg;
        is_zero <= is_zero;
    end
end

// ────── 以下部分积产生、跳零、优先级逻辑与之前完全相同 ──────
always @(*) begin
    case (PP6)
        3'b000: PP6_partial_product = 28'd0;
        3'b001: PP6_partial_product = {{14{a_frac[13]}},a_frac};
        3'b010: PP6_partial_product = {{14{a_fracx2[13]}},a_fracx2};
        3'b111: PP6_partial_product = {{14{a_frac_minus[13]}},a_frac_minus};
        3'b110: PP6_partial_product = {{14{a_fracx2_minus[13]}},a_fracx2_minus};
        default: PP6_partial_product = 28'd0;
    endcase
end

always @(*) begin
    case (PP5)
        3'b000: PP5_partial_product = 28'd0;
        3'b001: PP5_partial_product = {{14{a_frac[13]}},a_frac};
        3'b010: PP5_partial_product = {{14{a_fracx2[13]}},a_fracx2};
        3'b111: PP5_partial_product = {{14{a_frac_minus[13]}},a_frac_minus};
        3'b110: PP5_partial_product = {{14{a_fracx2_minus[13]}},a_fracx2_minus};
        default: PP5_partial_product = 28'd0;
    endcase
end

always @(*) begin
    case (PP4)
        3'b000: PP4_partial_product = 28'd0;
        3'b001: PP4_partial_product = {{14{a_frac[13]}},a_frac};
        3'b010: PP4_partial_product = {{14{a_fracx2[13]}},a_fracx2};
        3'b111: PP4_partial_product = {{14{a_frac_minus[13]}},a_frac_minus};
        3'b110: PP4_partial_product = {{14{a_fracx2_minus[13]}},a_fracx2_minus};
        default: PP4_partial_product = 28'd0;
    endcase
end

always @(*) begin
    case (PP3)
        3'b000: PP3_partial_product = 28'd0;
        3'b001: PP3_partial_product = {{14{a_frac[13]}},a_frac};
        3'b010: PP3_partial_product = {{14{a_fracx2[13]}},a_fracx2};
        3'b111: PP3_partial_product = {{14{a_frac_minus[13]}},a_frac_minus};
        3'b110: PP3_partial_product = {{14{a_fracx2_minus[13]}},a_fracx2_minus};
        default: PP3_partial_product = 28'd0;
    endcase
end

always @(*) begin
    case (PP2)
        3'b000: PP2_partial_product = 28'd0;
        3'b001: PP2_partial_product = {{14{a_frac[13]}},a_frac};
        3'b010: PP2_partial_product = {{14{a_fracx2[13]}},a_fracx2};
        3'b111: PP2_partial_product = {{14{a_frac_minus[13]}},a_frac_minus};
        3'b110: PP2_partial_product = {{14{a_fracx2_minus[13]}},a_fracx2_minus};
        default: PP2_partial_product = 28'd0;
    endcase
end

always @(*) begin
    case (PP1)
        3'b000: PP1_partial_product = 28'd0;
        3'b001: PP1_partial_product = {{14{a_frac[13]}},a_frac};
        3'b010: PP1_partial_product = {{14{a_fracx2[13]}},a_fracx2};
        3'b111: PP1_partial_product = {{14{a_frac_minus[13]}},a_frac_minus};
        3'b110: PP1_partial_product = {{14{a_fracx2_minus[13]}},a_fracx2_minus};
        default: PP1_partial_product = 28'd0;
    endcase
end

always @(*) begin
    case (PP0)
        3'b000: PP0_partial_product = 28'd0;
        3'b001: PP0_partial_product = {{14{a_frac[13]}},a_frac};
        3'b010: PP0_partial_product = {{14{a_fracx2[13]}},a_fracx2};
        3'b111: PP0_partial_product = {{14{a_frac_minus[13]}},a_frac_minus};
        3'b110: PP0_partial_product = {{14{a_fracx2_minus[13]}},a_fracx2_minus};
        default: PP0_partial_product = 28'd0;
    endcase
end

// is_zero 标记更新（计算过程中，已处理组置1）
always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        is_zero <= 4'b0000;
    end
    else if (data_vld_wgt_i & data_rdy_wgt_o) begin
        is_zero <= is_zero_i;          // 加载新数据时覆盖
    end
    else if ((state == CALCULATE) & ~data_vld_o) begin
        case (proc_position)
            2'd3: is_zero <= {1'b1, is_zero[2:0]};
            2'd2: is_zero <= {is_zero[3], 1'b1, is_zero[1:0]};
            2'd1: is_zero <= {is_zero[3:2], 1'b1, is_zero[0]};
            2'd0: is_zero <= {is_zero[3:1], 1'b1};
        endcase
    end
    else begin
        is_zero <= is_zero;
    end
end

always @(*) begin
    casex (is_zero)
        4'b0xxx: partial_product = (PP6_partial_product << 12) + (PP5_partial_product << 10);
        4'b10xx: partial_product = (PP4_partial_product << 8) + (PP3_partial_product << 6);
        4'b110x: partial_product = (PP2_partial_product << 4) + (PP1_partial_product << 2);
        4'b1110: partial_product = (PP0_partial_product);
        default: partial_product = 0;
    endcase
end

always @(*) begin
    casex (is_zero)
        4'b0xxx: proc_position = 2'd3;
        4'b10xx: proc_position = 2'd2;
        4'b110x: proc_position = 2'd1;
        4'b1110: proc_position = 2'd0;
        default: proc_position = 2'd0;
    endcase
end

assign result_frac_o = result_frac;
assign data_vld_o = (state == CALCULATE) & (cyc_cnt == cyc_avg);

endmodule