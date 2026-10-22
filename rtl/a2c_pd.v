`timescale 1ns/1ps
module a2c_pd#(
    parameter DATA_WIDTH = 16,
    parameter EXPONENT_WIDTH = 8,
    parameter FRACTION_WIDTH = 14,
    parameter POSIT_16 = 1'b1,
    parameter POSIT_8 = 1'b0
)
(
    input  wire                      clk_333MHz_i,
    input  wire                      rst_n_i     ,
    input  wire [DATA_WIDTH-1:0]     data_i      ,
    input  wire                      data_vld_i  ,
    input  wire                      data_rdy_i  ,
    input  wire                      data_mode_i ,
    output wire [EXPONENT_WIDTH-1:0] exp_o       ,
    output wire [FRACTION_WIDTH-1:0] frac_o      ,
    output wire                      data_rdy_o  ,
    output wire                      data_vld_o  
);
    reg  [DATA_WIDTH + 1:0] data_reg                ; // error_bit | dir_bit | sgn_bit | following bits 
    reg  [1:0] move_state                           ;
    reg  [2:0] regime_result                        ;
    reg  regime_decode_done                         ;      
    reg  is_busy                                    ;
    wire [DATA_WIDTH-2:0] data_shift                ;
    wire tmp_result, t3, t2, t1, t0, n1, n2, n3, n4 ;
    wire [7:0]  xnor_result                         ;
    wire [1:0]  exponent                            ;
    wire [10:0] fraction                            ;
    wire signed [4:0]  regime                       ;
    wire signed [4:0]  regime_length                ;

    // 以下三根线网改为单独 assign
    wire sign;
    wire dir;
    wire error;

    assign sign  = data_reg[15];
    assign dir   = data_reg[16];
    assign error = data_reg[17];

    assign data_shift = (move_state == 2'b11) ? {data_reg[6:0], 8'b0000_0000} : 
                        (move_state == 2'b10) ? {data_reg[10:0], 4'b0000} : 
                        (move_state == 2'b01) ? {data_reg[12:0], 2'b00} : 
                        15'b000_0000_0000_0000;

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            move_state <= 2'b00;
        end
        else if (data_vld_i & data_rdy_o & (data_mode_i == POSIT_16)) begin
            move_state <= 2'b11;
        end
        else if (data_vld_i & data_rdy_o & (data_mode_i == POSIT_8)) begin
            move_state <= 2'b10;
        end
        else if (|move_state) begin
            move_state <= move_state - 1'b1;
        end
        else begin
            move_state <= move_state;
        end
    end

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            data_reg <= 18'b0000_0000_0000_0000_00;
        end
        else if (data_vld_i & data_rdy_o) begin
            data_reg <= {|data_i[14:0], data_i[14], data_i};
        end
        else if (|move_state & tmp_result & data_reg[17]) begin
            data_reg <= {data_reg[17:15], data_shift};
        end
        else begin
            data_reg <= data_reg;
        end
    end

    assign xnor_result = ~({8{dir}}^data_reg[14:7]);
    assign t0 = xnor_result[7];
    assign t1 = (xnor_result[7] & xnor_result[6]);
    assign n1 = (xnor_result[5] & xnor_result[4]);
    assign n2 = (xnor_result[3] & xnor_result[2]);
    assign n3 = (xnor_result[1] & xnor_result[0]);
    assign t2 = t1 & n1;
    assign n4 = n2 & n3;
    assign t3 = t2 & n4;
    assign tmp_result = (move_state == 2'b11) ? t3 : 
                        (move_state == 2'b10) ? t2 : 
                        (move_state == 2'b01) ? t1 : t0;

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (~rst_n_i) begin 
            regime_result <= 3'b000;
        end
        else if (data_rdy_o & data_vld_i) begin
            regime_result <= 3'b000;
        end
        else if (|move_state & data_reg[17]) begin
            regime_result <= {regime_result[1:0], tmp_result};
        end
        else begin
            regime_result <= regime_result;
        end
    end

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            regime_decode_done <= 1'b0;
        end
        else if (data_rdy_o & data_vld_i) begin
            regime_decode_done <= 1'b0;
        end
        else if (move_state == 2'b01) begin
            regime_decode_done <= 1'b1;
        end
        else if (regime_decode_done & data_rdy_i) begin
            regime_decode_done <= 1'b0;
        end
        else begin
            regime_decode_done <= regime_decode_done;
        end
    end

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            is_busy <= 1'b0;
        end
        else if (data_vld_i & data_rdy_o) begin
            is_busy <= 1'b1;
        end
        else if (regime_decode_done & data_rdy_i) begin
            is_busy <= 1'b0;
        end
        else begin
            is_busy <= is_busy;
        end 
    end

    assign data_vld_o    = regime_decode_done;
    assign data_rdy_o    = ~is_busy;
    assign exponent      = t0 ? data_reg[12:11] : data_reg[13:12];
    assign fraction      = t0 ? data_reg[10:0]  : data_reg[11:1] ;
    assign regime_length = {1'b0, regime_result, t0};
    assign regime        = data_reg[16] ? (regime_length - 1) : (-regime_length);
    assign exp_o         = data_reg[17] ? (sign ? ~{regime[4], regime, exponent} : {regime[4], regime, exponent}) : 8'b0000_0000;
    assign frac_o        = data_reg[17] ? (sign ? {3'b110, fraction} : {3'b001, fraction}) : {14{1'b0}};    

endmodule