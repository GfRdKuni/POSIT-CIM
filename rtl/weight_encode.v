`timescale 1ns/1ps
module weight_encode #(
    parameter DATA_WIDTH = 14
)
(
    input  wire                         clk_333MHz_i ,
    input  wire                         rst_n_i      ,
    input  wire        [DATA_WIDTH-1:0] data_i       ,
    input  wire                         data_vld_i   ,
    input  wire                         data_rdy_i   ,
    output wire                         data_vld_o   ,
    output wire                         data_rdy_o   ,
    output wire signed [2:0]            PP6_o        ,
    output wire signed [2:0]            PP5_o        ,
    output wire signed [2:0]            PP4_o        ,
    output wire signed [2:0]            PP3_o        ,
    output wire signed [2:0]            PP2_o        ,
    output wire signed [2:0]            PP1_o        ,
	output wire signed [2:0]            PP0_o        ,
    output wire        [3:0]            is_zero_o     
);

    reg [DATA_WIDTH:0]  data_reg;
    reg                 is_idle ;
    reg [2:0]           PP6     ;
    reg [2:0]           PP5     ;
    reg [2:0]           PP4     ;
    reg [2:0]           PP3     ;
    reg [2:0]           PP2     ;
    reg [2:0]           PP1     ;
    reg [2:0]           PP0     ;



    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            data_reg <= 15'd0;
        end
        else if (data_vld_i & data_rdy_o) begin
            data_reg <= {data_i, 1'b0};
        end
        else begin
            data_reg <= data_reg;
        end
    end

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            is_idle <= 1'b1;
        end
        else if (data_rdy_o & data_vld_i) begin
            is_idle <= 1'b0;
        end
        else if (data_vld_o & data_rdy_i) begin
            is_idle <= 1'b1;
        end
        else begin
            is_idle <= is_idle;
        end
    end

    // ==================== PP6：data_reg[13], data_reg[12], data_reg[11] ====================
    always @(*) begin
        case ({data_reg[14], data_reg[13], data_reg[12]})
            3'b000: PP6 = 3'b000;  // 0
            3'b001: PP6 = 3'b001;  // +1
            3'b010: PP6 = 3'b001;  // +1
            3'b011: PP6 = 3'b010;  // +2
            3'b100: PP6 = 3'b110;  // -2
            3'b101: PP6 = 3'b111;  // -1
            3'b110: PP6 = 3'b111;  // -1
            3'b111: PP6 = 3'b000;  // 0
            default: PP6 = 3'b000;
        endcase
    end

    // ==================== PP5：data_reg[11], data_reg[10], data_reg[9] ====================
    always @(*) begin
        case ({data_reg[12], data_reg[11], data_reg[10]})
            3'b000: PP5 = 3'b000;
            3'b001: PP5 = 3'b001;
            3'b010: PP5 = 3'b001;
            3'b011: PP5 = 3'b010;
            3'b100: PP5 = 3'b110;
            3'b101: PP5 = 3'b111;
            3'b110: PP5 = 3'b111;
            3'b111: PP5 = 3'b000;
            default: PP5 = 3'b000;
        endcase
    end

    // ==================== PP4：data_reg[9], data_reg[8], data_reg[7] ====================
    always @(*) begin
        case ({data_reg[10], data_reg[9], data_reg[8]})
            3'b000: PP4 = 3'b000;
            3'b001: PP4 = 3'b001;
            3'b010: PP4 = 3'b001;
            3'b011: PP4 = 3'b010;
            3'b100: PP4 = 3'b110;
            3'b101: PP4 = 3'b111;
            3'b110: PP4 = 3'b111;
            3'b111: PP4 = 3'b000;
            default: PP4 = 3'b000;
        endcase
    end

    // ==================== PP3：data_reg[7], data_reg[6], data_reg[5] ====================
    always @(*) begin
        case ({data_reg[8], data_reg[7], data_reg[6]})
            3'b000: PP3 = 3'b000;
            3'b001: PP3 = 3'b001;
            3'b010: PP3 = 3'b001;
            3'b011: PP3 = 3'b010;
            3'b100: PP3 = 3'b110;
            3'b101: PP3 = 3'b111;
            3'b110: PP3 = 3'b111;
            3'b111: PP3 = 3'b000;
            default: PP3 = 3'b000;
        endcase
    end

    // ==================== PP2：data_reg[5], data_reg[4], data_reg[3] ====================
    always @(*) begin
        case ({data_reg[6], data_reg[5], data_reg[4]})
            3'b000: PP2 = 3'b000;
            3'b001: PP2 = 3'b001;
            3'b010: PP2 = 3'b001;
            3'b011: PP2 = 3'b010;
            3'b100: PP2 = 3'b110;
            3'b101: PP2 = 3'b111;
            3'b110: PP2 = 3'b111;
            3'b111: PP2 = 3'b000;
            default: PP2 = 3'b000;
        endcase
    end

    // ==================== PP1：data_reg[3], data_reg[2], data_reg[1] ====================
    always @(*) begin
        case ({data_reg[4], data_reg[3], data_reg[2]})
            3'b000: PP1 = 3'b000;
            3'b001: PP1 = 3'b001;
            3'b010: PP1 = 3'b001;
            3'b011: PP1 = 3'b010;
            3'b100: PP1 = 3'b110;
            3'b101: PP1 = 3'b111;
            3'b110: PP1 = 3'b111;
            3'b111: PP1 = 3'b000;
            default: PP1 = 3'b000;
        endcase
    end

    // ==================== PP0：data_reg[1], data_reg[0], 1'b0（最低位固定补0）====================
    always @(*) begin
        case ({data_reg[2], data_reg[1], data_reg[0]})
            3'b000: PP0 = 3'b000;
            3'b001: PP0 = 3'b001;
            3'b010: PP0 = 3'b001;
            3'b011: PP0 = 3'b010;
            3'b100: PP0 = 3'b110;
            3'b101: PP0 = 3'b111;
            3'b110: PP0 = 3'b111;
            3'b111: PP0 = 3'b000;
            default: PP0 = 3'b000;
        endcase
    end

    assign data_rdy_o    = is_idle           ;
    assign data_vld_o   = ~is_idle          ;
    assign PP6_o        = PP6               ;
    assign PP5_o        = PP5               ;
    assign PP4_o        = PP4               ;  
    assign PP3_o        = PP3               ;  
    assign PP2_o        = PP2               ;  
    assign PP1_o        = PP1               ;  
    assign PP0_o        = PP0               ;  
    assign is_zero_o[3] = (~|PP6) & (~|PP5) ;
    assign is_zero_o[2] = (~|PP4) & (~|PP3) ;
    assign is_zero_o[1] = (~|PP2) & (~|PP1) ;
    assign is_zero_o[0] = (~|PP0)           ;  
endmodule