`timescale 1ns/1ps
module msa_dcm#(
    parameter DATA_WIDTH = 14,
    parameter IDLE       = 1'b0,
    parameter CALCULATE  = 1'b1
)
(
    input  wire                           clk_333MHz_i    ,
    input  wire                           rst_n_i         ,
    input  wire        [DATA_WIDTH-1:0]   a_frac_i        ,
    input  wire        [DATA_WIDTH-1:0]   a_frac_ix2      ,
    input  wire        [DATA_WIDTH-1:0]   a_frac_i_minus  ,
    input  wire        [DATA_WIDTH-1:0]   a_frac_ix2_minus,
    input  wire signed [2:0]              PP6_i           ,
    input  wire signed [2:0]              PP5_i           ,
    input  wire signed [2:0]              PP4_i           ,
    input  wire signed [2:0]              PP3_i           ,
    input  wire signed [2:0]              PP2_i           ,
    input  wire signed [2:0]              PP1_i           ,
    input  wire signed [2:0]              PP0_i           ,
    input  wire        [2:0]              cyc_avg_i       ,
    input  wire        [3:0]              is_zero_i       ,
    input  wire                           start_i         ,
    input  wire                           data_rdy_i      ,
    output wire        [DATA_WIDTH*2-1:0] result_frac_o   ,
    output wire                           is_idle_o       ,
    output wire                           data_vld_o      
);

reg signed [DATA_WIDTH*2-1:0] result_frac        ;
reg        [2:0]              cyc_cnt            ;
reg                           state              ; // 0: idle, 1: calculating
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

always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        state <= IDLE;
    end
    else if (start_i & (state == IDLE)) begin
        state <= CALCULATE;
    end
    else if (state == CALCULATE & data_vld_o & data_rdy_i) begin
        state <= IDLE;
    end
end

always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        cyc_cnt <= 0;
    end
    else if (start_i) begin
        cyc_cnt <= 0;
    end
    else if (state == CALCULATE & ~data_vld_o) begin
        cyc_cnt <= cyc_cnt + 1;
    end
    else if (data_vld_o & data_rdy_i) begin
        cyc_cnt <= 0;
    end
    else begin
        cyc_cnt <= cyc_cnt;
    end
end

always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        result_frac <= 0;
    end
    else if (start_i) begin
        result_frac <= 0;
    end
    else if (state == CALCULATE & ~data_vld_o) begin
        result_frac <= result_frac + partial_product;
    end
    else begin
        result_frac <= result_frac;
    end
end

always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        a_frac <= 0;
        a_fracx2 <= 0;
        a_frac_minus <= 0;
        a_fracx2_minus <= 0;
        PP6 <= 0;
        PP5 <= 0;
        PP4 <= 0;
        PP3 <= 0;
        PP2 <= 0;
        PP1 <= 0;
        PP0 <= 0;
        cyc_avg <= 0;
    end
    else if (start_i & is_idle_o) begin
        a_frac <= a_frac_i;
        a_fracx2 <= a_frac_ix2;
        a_frac_minus <= a_frac_i_minus;
        a_fracx2_minus <= a_frac_ix2_minus;
        PP6 <= PP6_i;
        PP5 <= PP5_i;
        PP4 <= PP4_i;
        PP3 <= PP3_i;
        PP2 <= PP2_i;
        PP1 <= PP1_i;
        PP0 <= PP0_i;
        cyc_avg <= cyc_avg_i;
    end
    else begin
        a_frac <= a_frac;
        a_fracx2 <= a_fracx2;
        a_frac_minus <= a_frac_minus;
        a_fracx2_minus <= a_fracx2_minus;
        PP6 <= PP6;
        PP5 <= PP5;
        PP4 <= PP4;
        PP3 <= PP3;
        PP2 <= PP2;
        PP1 <= PP1;
        PP0 <= PP0;
        cyc_avg <= cyc_avg;
    end
end

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




always @(posedge clk_333MHz_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        is_zero <= 4'b0000;
    end
    else if (start_i & is_idle_o) begin
        is_zero <= is_zero_i;
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
assign is_idle_o = (state == IDLE);

endmodule
