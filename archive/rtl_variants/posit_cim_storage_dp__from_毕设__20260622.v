`timescale 1ns/1ps
module posit_cim_storage_dp #(
    parameter DATA_WIDTH = 256,
    parameter ADDR_WIDTH = 10,
    parameter DEPTH = 1024,
    parameter POSIT_16 = 1'b1,
    parameter POSIT_8 = 1'b0
)
(
    input  wire                  clk_333MHz_i,
    input  wire                  rst_n_i     ,
    input  wire [DATA_WIDTH-1:0] w_data_i    ,
    input  wire [DATA_WIDTH-1:0] a_data_i    ,
    input  wire [ADDR_WIDTH-1:0] sram_addr_i ,
    input  wire                  ce_n_i      ,
    input  wire                  we_n_i      ,
    input  wire                  data_rdy_i  ,
    input  wire                  data_mode   , // 0: posit_8, 1: posit_16
    output wire [DATA_WIDTH-1:0] w_data_o    ,
    output wire [DATA_WIDTH-1:0] a_data_o    ,
    output wire                  data_vld_o  
);

    wire [DATA_WIDTH-1:0] w_sram_rdata;
    wire [DATA_WIDTH-1:0] a_sram_rdata;
    wire [DATA_WIDTH-1:0] w_data_d;
    wire [DATA_WIDTH-1:0] a_data_d;
    wire eff_read_en = ~ce_n_i & we_n_i;
    reg  sram_data_vld_d, sram_data_vld;
    reg  posit_8_cnt;


    posit_cim_storage_wrapper w_sram_1024x256_inst(
        .clk(clk_333MHz_i),            // 系统时钟
        .ce_n(ce_n_i),                 // 芯片使能 (Active Low)
        .we_n(we_n_i),                 // 写使能   (Active Low)
        .logical_addr(sram_addr_i), 
        .wdata(w_data_i),              // 256-bit 写入数据
        .rdata(w_sram_rdata)           // 256-bit 读出数据
    );

    posit_cim_storage_wrapper a_sram_1024x256_inst(
        .clk(clk_333MHz_i),            // 系统时钟
        .ce_n(ce_n_i),                 // 芯片使能 (Active Low)
        .we_n(we_n_i),                 // 写使能   (Active Low)
        .logical_addr(sram_addr_i), 
        .wdata(a_data_i),              // 256-bit 写入数据
        .rdata(a_sram_rdata)           // 256-bit 读出数据
    );


    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            sram_data_vld_d <= 1'b0;
        end
        else begin
            sram_data_vld_d <= eff_read_en;
        end
    end

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            sram_data_vld <= 1'b0;
        end
        else if (sram_data_vld_d) begin
            sram_data_vld <= 1'b1;
        end
        else if (sram_data_vld & data_rdy_i & ((data_mode == POSIT_16) | posit_8_cnt)) begin
            sram_data_vld <= 1'b0;
        end
        else begin
            sram_data_vld <= sram_data_vld;
        end
    end

    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            posit_8_cnt <= 1'b0;
        end
        else if (sram_data_vld && (data_mode == POSIT_8) && ~posit_8_cnt && data_rdy_i) begin
            posit_8_cnt <= 1'b1;
        end
        else if (posit_8_cnt && data_rdy_i == 1'b1 && sram_data_vld) begin
            posit_8_cnt <= 1'b0;
        end
    end

    assign w_data_do = (data_mode == POSIT_16) ? w_sram_rdata :
                 (posit_8_cnt == 1'b0) ? 
                 {
                    {w_sram_rdata[255:248], 8'b0000_0000},
                    {w_sram_rdata[247:240], 8'b0000_0000},
                    {w_sram_rdata[239:232], 8'b0000_0000},
                    {w_sram_rdata[231:224], 8'b0000_0000},
                    {w_sram_rdata[223:216], 8'b0000_0000},
                    {w_sram_rdata[215:208], 8'b0000_0000},
                    {w_sram_rdata[207:200], 8'b0000_0000},
                    {w_sram_rdata[199:192], 8'b0000_0000},
                    {w_sram_rdata[191:184], 8'b0000_0000},
                    {w_sram_rdata[183:176], 8'b0000_0000},
                    {w_sram_rdata[175:168], 8'b0000_0000},
                    {w_sram_rdata[167:160], 8'b0000_0000},
                    {w_sram_rdata[159:152], 8'b0000_0000},
                    {w_sram_rdata[151:144], 8'b0000_0000},
                    {w_sram_rdata[143:136], 8'b0000_0000},
                    {w_sram_rdata[135:128], 8'b0000_0000}
                 } : 
                 {
                    {w_sram_rdata[127:120], 8'b0000_0000},
                    {w_sram_rdata[119:112], 8'b0000_0000},
                    {w_sram_rdata[111:104], 8'b0000_0000},
                    {w_sram_rdata[103:96],  8'b0000_0000},
                    {w_sram_rdata[95:88],   8'b0000_0000},
                    {w_sram_rdata[87:80],   8'b0000_0000},
                    {w_sram_rdata[79:72],   8'b0000_0000},
                    {w_sram_rdata[71:64],   8'b0000_0000},
                    {w_sram_rdata[63:56],   8'b0000_0000},
                    {w_sram_rdata[55:48],   8'b0000_0000},
                    {w_sram_rdata[47:40],   8'b0000_0000},
                    {w_sram_rdata[39:32],   8'b0000_0000},
                    {w_sram_rdata[31:24],   8'b0000_0000},
                    {w_sram_rdata[23:16],   8'b0000_0000},
                    {w_sram_rdata[15:8],    8'b0000_0000},
                    {w_sram_rdata[7:0],     8'b0000_0000}
                 };

    assign a_data_o = (data_mode == POSIT_16) ? a_sram_rdata :
             (posit_8_cnt == 1'b0) ? 
             {   
                {a_sram_rdata[255:248], 8'b0000_0000},
                {a_sram_rdata[247:240], 8'b0000_0000},
                {a_sram_rdata[239:232], 8'b0000_0000},
                {a_sram_rdata[231:224], 8'b0000_0000},
                {a_sram_rdata[223:216], 8'b0000_0000},
                {a_sram_rdata[215:208], 8'b0000_0000},
                {a_sram_rdata[207:200], 8'b0000_0000},
                {a_sram_rdata[199:192], 8'b0000_0000},
                {a_sram_rdata[191:184], 8'b0000_0000},
                {a_sram_rdata[183:176], 8'b0000_0000},
                {a_sram_rdata[175:168], 8'b0000_0000},
                {a_sram_rdata[167:160], 8'b0000_0000},
                {a_sram_rdata[159:152], 8'b0000_0000},
                {a_sram_rdata[151:144], 8'b0000_0000},
                {a_sram_rdata[143:136], 8'b0000_0000},
                {a_sram_rdata[135:128], 8'b0000_0000}
             } : 
             {   
                {a_sram_rdata[127:120], 8'b0000_0000},
                {a_sram_rdata[119:112], 8'b0000_0000},
                {a_sram_rdata[111:104], 8'b0000_0000},
                {a_sram_rdata[103:96],  8'b0000_0000},
                {a_sram_rdata[95:88],   8'b0000_0000},
                {a_sram_rdata[87:80],   8'b0000_0000},
                {a_sram_rdata[79:72],   8'b0000_0000},
                {a_sram_rdata[71:64],   8'b0000_0000},
                {a_sram_rdata[63:56],   8'b0000_0000},
                {a_sram_rdata[55:48],   8'b0000_0000},
                {a_sram_rdata[47:40],   8'b0000_0000},
                {a_sram_rdata[39:32],   8'b0000_0000},
                {a_sram_rdata[31:24],   8'b0000_0000},
                {a_sram_rdata[23:16],   8'b0000_0000},
                {a_sram_rdata[15:8],    8'b0000_0000},
                {a_sram_rdata[7:0],     8'b0000_0000}
             };

    assign data_vld_o = sram_data_vld;

endmodule