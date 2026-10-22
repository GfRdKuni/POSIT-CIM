`timescale 1ns/1ps
module act_lut_setup#(
    parameter DATA_WIDTH = 14,
    parameter IDLE       = 1'b0,
    parameter BUSY       = 1'b1
)
(
    input  wire                  clk_333MHz_i    ,
    input  wire                  rst_n_i         ,
    input  wire [DATA_WIDTH-1:0] data_i          ,
    input  wire                  data_vld_i      ,
    input  wire                  data_rdy_i      ,
    output wire                  data_vld_o      ,
    output wire                  data_rdy_o      ,
    output wire [DATA_WIDTH-1:0] a_frac_o        ,
    output wire [DATA_WIDTH-1:0] a_fracx2_o      ,
    output wire [DATA_WIDTH-1:0] a_frac_minus_o  ,
    output wire [DATA_WIDTH-1:0] a_fracx2_minus_o,
);
    reg [DATA_WIDTH-1:0] data_reg;
    reg                  state   ;

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state <= IDLE;
        end
        else if (data_rdy_o & data_vld_i) begin
            state <= BUSY;
        end
        else if (data_vld_o & data_rdy_i) begin
            state <= IDLE;
        end
        else begin
            state <= state;
        end
    end

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            data_reg <= 0;
        end
        else if (data_rdy_o && data_vld_i) begin
            data_reg <= data_i;
        end
        else begin
            data_reg <= data_reg;
        end
    end

    assign a_frac_o = data_reg;
    assign a_fracx2_o = {data_reg[DATA_WIDTH-2:0], 1'b0};
    assign a_frac_minus_o = ~data_reg + 1'b1;
    assign a_fracx2_minus_o = {a_frac_minus_o[DATA_WIDTH-2:0], 1'b0};

    assign data_vld_o = (state == BUSY);
    assign data_rdy_o = (state == IDLE);
endmodule