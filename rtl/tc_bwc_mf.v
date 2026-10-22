`timescale 1ns/1ps
module tc_bwc_mf #(
    parameter DATA_WIDTH = 8 ,
    parameter LANE_WIDTH = 16,
    parameter IDLE       = 2'b00,
    parameter PHASE1     = 2'b01,
    parameter PHASE2     = 2'b10,
    parameter PHASE3     = 2'b11
)
(
    input  wire                             clk_333MHz_i,
    input  wire                             rst_n_i,
    input  wire                             data_vld_i,
    input  wire                             data_rdy_i,
    input  wire [DATA_WIDTH*LANE_WIDTH-1:0] data_i,
    output wire                             data_vld_o,
    output wire                             data_rdy_o,
    output wire [DATA_WIDTH-1:0]            max_exp_o,
    output wire [DATA_WIDTH*LANE_WIDTH-1:0] delta_exp_o
);

    // ────── 输入锁存寄存器（16 lanes） ──────
    reg [7:0] r0, r1, r2, r3, r4, r5, r6, r7,
              r8, r9, r10, r11, r12, r13, r14, r15;

    // ────── 状态机 ──────
    reg [1:0] state, next_state;

    // ────── 流水线中间寄存器 ──────
    reg [2:0] max_high1;       // {max7, max6, max5}
    reg [15:0] mask_mid1;      // 进入第二段的掩码 (mask5)

    reg [2:0] max_mid2;        // {max4, max3, max2}
    reg [15:0] mask_mid2;      // 进入第三段的掩码 (mask2)

    // ────── 组合逻辑线网 ──────
    // 第一段：位7,6,5
    wire max7, max6, max5;
    wire [15:0] mask7, mask6, mask5;

    // 第二段：位4,3,2（基于 mask_mid1）
    wire max4, max3, max2;
    wire [15:0] mask4, mask3, mask2;

    // 第三段：位1,0（基于 mask_mid2）
    wire max1, max0;
    wire [15:0] mask1;         // mask0 不用

    // ────── 状态跳转 ──────
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
                if (data_vld_i && data_rdy_o) begin next_state = PHASE1; end
                else begin next_state = IDLE; end
            end
            PHASE1: next_state = PHASE2;
            PHASE2: next_state = PHASE3;
            PHASE3: begin
                if (data_vld_o && data_rdy_i) begin next_state = IDLE; end
                else begin next_state = PHASE3; end
            end
            default: next_state = IDLE;
        endcase
    end

    // ────── 输入数据锁存（仅 IDLE 握手时） ──────
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            r0 <= 0; r1 <= 0; r2 <= 0; r3 <= 0;
            r4 <= 0; r5 <= 0; r6 <= 0; r7 <= 0;
            r8 <= 0; r9 <= 0; r10 <= 0; r11 <= 0;
            r12 <= 0; r13 <= 0; r14 <= 0; r15 <= 0;
        end else if (data_vld_i && data_rdy_o) begin
            r0  <= data_i[1*8-1:0*8];
            r1  <= data_i[2*8-1:1*8];
            r2  <= data_i[3*8-1:2*8];
            r3  <= data_i[4*8-1:3*8];
            r4  <= data_i[5*8-1:4*8];
            r5  <= data_i[6*8-1:5*8];
            r6  <= data_i[7*8-1:6*8];
            r7  <= data_i[8*8-1:7*8];
            r8  <= data_i[9*8-1:8*8];
            r9  <= data_i[10*8-1:9*8];
            r10 <= data_i[11*8-1:10*8];
            r11 <= data_i[12*8-1:11*8];
            r12 <= data_i[13*8-1:12*8];
            r13 <= data_i[14*8-1:13*8];
            r14 <= data_i[15*8-1:14*8];
            r15 <= data_i[16*8-1:15*8];
        end else begin
            r0  <= r0;  r1  <= r1;  r2  <= r2;  r3  <= r3;
            r4  <= r4;  r5  <= r5;  r6  <= r6;  r7  <= r7;
            r8  <= r8;  r9  <= r9;  r10 <= r10; r11 <= r11;
            r12 <= r12; r13 <= r13; r14 <= r14; r15 <= r15;
        end
    end

    // ────── 第一段组合逻辑：位7,6,5 (基于 r0~r15) ──────
    // max7 符号位 AND 归约（无需分层）
    assign max7 = r0[7] & r1[7] & r2[7] & r3[7] &
                  r4[7] & r5[7] & r6[7] & r7[7] &
                  r8[7] & r9[7] & r10[7] & r11[7] &
                  r12[7] & r13[7] & r14[7] & r15[7];

    assign mask7[0]  = ~(r0[7]  ^ max7);
    assign mask7[1]  = ~(r1[7]  ^ max7);
    assign mask7[2]  = ~(r2[7]  ^ max7);
    assign mask7[3]  = ~(r3[7]  ^ max7);
    assign mask7[4]  = ~(r4[7]  ^ max7);
    assign mask7[5]  = ~(r5[7]  ^ max7);
    assign mask7[6]  = ~(r6[7]  ^ max7);
    assign mask7[7]  = ~(r7[7]  ^ max7);
    assign mask7[8]  = ~(r8[7]  ^ max7);
    assign mask7[9]  = ~(r9[7]  ^ max7);
    assign mask7[10] = ~(r10[7] ^ max7);
    assign mask7[11] = ~(r11[7] ^ max7);
    assign mask7[12] = ~(r12[7] ^ max7);
    assign mask7[13] = ~(r13[7] ^ max7);
    assign mask7[14] = ~(r14[7] ^ max7);
    assign mask7[15] = ~(r15[7] ^ max7);

    // max6 分层 OR
    wire grp0_max6, grp1_max6, grp2_max6, grp3_max6;
    assign grp0_max6 = (r0[6] & mask7[0]) | (r1[6] & mask7[1]) | (r2[6] & mask7[2]) | (r3[6] & mask7[3]);
    assign grp1_max6 = (r4[6] & mask7[4]) | (r5[6] & mask7[5]) | (r6[6] & mask7[6]) | (r7[6] & mask7[7]);
    assign grp2_max6 = (r8[6] & mask7[8]) | (r9[6] & mask7[9]) | (r10[6] & mask7[10]) | (r11[6] & mask7[11]);
    assign grp3_max6 = (r12[6] & mask7[12]) | (r13[6] & mask7[13]) | (r14[6] & mask7[14]) | (r15[6] & mask7[15]);
    assign max6 = grp0_max6 | grp1_max6 | grp2_max6 | grp3_max6;

    assign mask6[0]  = mask7[0]  & ~(r0[6]  ^ max6);
    assign mask6[1]  = mask7[1]  & ~(r1[6]  ^ max6);
    assign mask6[2]  = mask7[2]  & ~(r2[6]  ^ max6);
    assign mask6[3]  = mask7[3]  & ~(r3[6]  ^ max6);
    assign mask6[4]  = mask7[4]  & ~(r4[6]  ^ max6);
    assign mask6[5]  = mask7[5]  & ~(r5[6]  ^ max6);
    assign mask6[6]  = mask7[6]  & ~(r6[6]  ^ max6);
    assign mask6[7]  = mask7[7]  & ~(r7[6]  ^ max6);
    assign mask6[8]  = mask7[8]  & ~(r8[6]  ^ max6);
    assign mask6[9]  = mask7[9]  & ~(r9[6]  ^ max6);
    assign mask6[10] = mask7[10] & ~(r10[6] ^ max6);
    assign mask6[11] = mask7[11] & ~(r11[6] ^ max6);
    assign mask6[12] = mask7[12] & ~(r12[6] ^ max6);
    assign mask6[13] = mask7[13] & ~(r13[6] ^ max6);
    assign mask6[14] = mask7[14] & ~(r14[6] ^ max6);
    assign mask6[15] = mask7[15] & ~(r15[6] ^ max6);

    // max5 分层 OR
    wire grp0_max5, grp1_max5, grp2_max5, grp3_max5;
    assign grp0_max5 = (r0[5] & mask6[0]) | (r1[5] & mask6[1]) | (r2[5] & mask6[2]) | (r3[5] & mask6[3]);
    assign grp1_max5 = (r4[5] & mask6[4]) | (r5[5] & mask6[5]) | (r6[5] & mask6[6]) | (r7[5] & mask6[7]);
    assign grp2_max5 = (r8[5] & mask6[8]) | (r9[5] & mask6[9]) | (r10[5] & mask6[10]) | (r11[5] & mask6[11]);
    assign grp3_max5 = (r12[5] & mask6[12]) | (r13[5] & mask6[13]) | (r14[5] & mask6[14]) | (r15[5] & mask6[15]);
    assign max5 = grp0_max5 | grp1_max5 | grp2_max5 | grp3_max5;

    assign mask5[0]  = mask6[0]  & ~(r0[5]  ^ max5);
    assign mask5[1]  = mask6[1]  & ~(r1[5]  ^ max5);
    assign mask5[2]  = mask6[2]  & ~(r2[5]  ^ max5);
    assign mask5[3]  = mask6[3]  & ~(r3[5]  ^ max5);
    assign mask5[4]  = mask6[4]  & ~(r4[5]  ^ max5);
    assign mask5[5]  = mask6[5]  & ~(r5[5]  ^ max5);
    assign mask5[6]  = mask6[6]  & ~(r6[5]  ^ max5);
    assign mask5[7]  = mask6[7]  & ~(r7[5]  ^ max5);
    assign mask5[8]  = mask6[8]  & ~(r8[5]  ^ max5);
    assign mask5[9]  = mask6[9]  & ~(r9[5]  ^ max5);
    assign mask5[10] = mask6[10] & ~(r10[5] ^ max5);
    assign mask5[11] = mask6[11] & ~(r11[5] ^ max5);
    assign mask5[12] = mask6[12] & ~(r12[5] ^ max5);
    assign mask5[13] = mask6[13] & ~(r13[5] ^ max5);
    assign mask5[14] = mask6[14] & ~(r14[5] ^ max5);
    assign mask5[15] = mask6[15] & ~(r15[5] ^ max5);

    // ────── 第一段流水线寄存器 ──────
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            max_high1 <= 3'b0;
            mask_mid1 <= 16'hFFFF;
        end else if (state == PHASE1) begin
            max_high1 <= {max7, max6, max5};
            mask_mid1 <= mask5;
        end else begin
            max_high1 <= max_high1;
            mask_mid1 <= mask_mid1;
        end
    end

    // ────── 第二段组合逻辑：位4,3,2 (基于 mask_mid1 和 r0~r15) ──────
    // max4 分层 OR
    wire grp0_max4, grp1_max4, grp2_max4, grp3_max4;
    assign grp0_max4 = (r0[4] & mask_mid1[0]) | (r1[4] & mask_mid1[1]) | (r2[4] & mask_mid1[2]) | (r3[4] & mask_mid1[3]);
    assign grp1_max4 = (r4[4] & mask_mid1[4]) | (r5[4] & mask_mid1[5]) | (r6[4] & mask_mid1[6]) | (r7[4] & mask_mid1[7]);
    assign grp2_max4 = (r8[4] & mask_mid1[8]) | (r9[4] & mask_mid1[9]) | (r10[4] & mask_mid1[10]) | (r11[4] & mask_mid1[11]);
    assign grp3_max4 = (r12[4] & mask_mid1[12]) | (r13[4] & mask_mid1[13]) | (r14[4] & mask_mid1[14]) | (r15[4] & mask_mid1[15]);
    assign max4 = grp0_max4 | grp1_max4 | grp2_max4 | grp3_max4;

    assign mask4[0]  = mask_mid1[0]  & ~(r0[4]  ^ max4);
    assign mask4[1]  = mask_mid1[1]  & ~(r1[4]  ^ max4);
    assign mask4[2]  = mask_mid1[2]  & ~(r2[4]  ^ max4);
    assign mask4[3]  = mask_mid1[3]  & ~(r3[4]  ^ max4);
    assign mask4[4]  = mask_mid1[4]  & ~(r4[4]  ^ max4);
    assign mask4[5]  = mask_mid1[5]  & ~(r5[4]  ^ max4);
    assign mask4[6]  = mask_mid1[6]  & ~(r6[4]  ^ max4);
    assign mask4[7]  = mask_mid1[7]  & ~(r7[4]  ^ max4);
    assign mask4[8]  = mask_mid1[8]  & ~(r8[4]  ^ max4);
    assign mask4[9]  = mask_mid1[9]  & ~(r9[4]  ^ max4);
    assign mask4[10] = mask_mid1[10] & ~(r10[4] ^ max4);
    assign mask4[11] = mask_mid1[11] & ~(r11[4] ^ max4);
    assign mask4[12] = mask_mid1[12] & ~(r12[4] ^ max4);
    assign mask4[13] = mask_mid1[13] & ~(r13[4] ^ max4);
    assign mask4[14] = mask_mid1[14] & ~(r14[4] ^ max4);
    assign mask4[15] = mask_mid1[15] & ~(r15[4] ^ max4);

    // max3 分层 OR
    wire grp0_max3, grp1_max3, grp2_max3, grp3_max3;
    assign grp0_max3 = (r0[3] & mask4[0]) | (r1[3] & mask4[1]) | (r2[3] & mask4[2]) | (r3[3] & mask4[3]);
    assign grp1_max3 = (r4[3] & mask4[4]) | (r5[3] & mask4[5]) | (r6[3] & mask4[6]) | (r7[3] & mask4[7]);
    assign grp2_max3 = (r8[3] & mask4[8]) | (r9[3] & mask4[9]) | (r10[3] & mask4[10]) | (r11[3] & mask4[11]);
    assign grp3_max3 = (r12[3] & mask4[12]) | (r13[3] & mask4[13]) | (r14[3] & mask4[14]) | (r15[3] & mask4[15]);
    assign max3 = grp0_max3 | grp1_max3 | grp2_max3 | grp3_max3;

    assign mask3[0]  = mask4[0]  & ~(r0[3]  ^ max3);
    assign mask3[1]  = mask4[1]  & ~(r1[3]  ^ max3);
    assign mask3[2]  = mask4[2]  & ~(r2[3]  ^ max3);
    assign mask3[3]  = mask4[3]  & ~(r3[3]  ^ max3);
    assign mask3[4]  = mask4[4]  & ~(r4[3]  ^ max3);
    assign mask3[5]  = mask4[5]  & ~(r5[3]  ^ max3);
    assign mask3[6]  = mask4[6]  & ~(r6[3]  ^ max3);
    assign mask3[7]  = mask4[7]  & ~(r7[3]  ^ max3);
    assign mask3[8]  = mask4[8]  & ~(r8[3]  ^ max3);
    assign mask3[9]  = mask4[9]  & ~(r9[3]  ^ max3);
    assign mask3[10] = mask4[10] & ~(r10[3] ^ max3);
    assign mask3[11] = mask4[11] & ~(r11[3] ^ max3);
    assign mask3[12] = mask4[12] & ~(r12[3] ^ max3);
    assign mask3[13] = mask4[13] & ~(r13[3] ^ max3);
    assign mask3[14] = mask4[14] & ~(r14[3] ^ max3);
    assign mask3[15] = mask4[15] & ~(r15[3] ^ max3);

    // max2 分层 OR
    wire grp0_max2, grp1_max2, grp2_max2, grp3_max2;
    assign grp0_max2 = (r0[2] & mask3[0]) | (r1[2] & mask3[1]) | (r2[2] & mask3[2]) | (r3[2] & mask3[3]);
    assign grp1_max2 = (r4[2] & mask3[4]) | (r5[2] & mask3[5]) | (r6[2] & mask3[6]) | (r7[2] & mask3[7]);
    assign grp2_max2 = (r8[2] & mask3[8]) | (r9[2] & mask3[9]) | (r10[2] & mask3[10]) | (r11[2] & mask3[11]);
    assign grp3_max2 = (r12[2] & mask3[12]) | (r13[2] & mask3[13]) | (r14[2] & mask3[14]) | (r15[2] & mask3[15]);
    assign max2 = grp0_max2 | grp1_max2 | grp2_max2 | grp3_max2;

    assign mask2[0]  = mask3[0]  & ~(r0[2]  ^ max2);
    assign mask2[1]  = mask3[1]  & ~(r1[2]  ^ max2);
    assign mask2[2]  = mask3[2]  & ~(r2[2]  ^ max2);
    assign mask2[3]  = mask3[3]  & ~(r3[2]  ^ max2);
    assign mask2[4]  = mask3[4]  & ~(r4[2]  ^ max2);
    assign mask2[5]  = mask3[5]  & ~(r5[2]  ^ max2);
    assign mask2[6]  = mask3[6]  & ~(r6[2]  ^ max2);
    assign mask2[7]  = mask3[7]  & ~(r7[2]  ^ max2);
    assign mask2[8]  = mask3[8]  & ~(r8[2]  ^ max2);
    assign mask2[9]  = mask3[9]  & ~(r9[2]  ^ max2);
    assign mask2[10] = mask3[10] & ~(r10[2] ^ max2);
    assign mask2[11] = mask3[11] & ~(r11[2] ^ max2);
    assign mask2[12] = mask3[12] & ~(r12[2] ^ max2);
    assign mask2[13] = mask3[13] & ~(r13[2] ^ max2);
    assign mask2[14] = mask3[14] & ~(r14[2] ^ max2);
    assign mask2[15] = mask3[15] & ~(r15[2] ^ max2);

    // ────── 第二段流水线寄存器 ──────
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            max_mid2 <= 3'b0;
            mask_mid2 <= 16'hFFFF;
        end else if (state == PHASE2) begin
            max_mid2 <= {max4, max3, max2};
            mask_mid2 <= mask2;
        end else begin
            max_mid2 <= max_mid2;
            mask_mid2 <= mask_mid2;
        end
    end

    // ────── 第三段组合逻辑：位1,0 (基于 mask_mid2 和 r0~r15) ──────
    // max1 分层 OR
    wire grp0_max1, grp1_max1, grp2_max1, grp3_max1;
    assign grp0_max1 = (r0[1] & mask_mid2[0]) | (r1[1] & mask_mid2[1]) | (r2[1] & mask_mid2[2]) | (r3[1] & mask_mid2[3]);
    assign grp1_max1 = (r4[1] & mask_mid2[4]) | (r5[1] & mask_mid2[5]) | (r6[1] & mask_mid2[6]) | (r7[1] & mask_mid2[7]);
    assign grp2_max1 = (r8[1] & mask_mid2[8]) | (r9[1] & mask_mid2[9]) | (r10[1] & mask_mid2[10]) | (r11[1] & mask_mid2[11]);
    assign grp3_max1 = (r12[1] & mask_mid2[12]) | (r13[1] & mask_mid2[13]) | (r14[1] & mask_mid2[14]) | (r15[1] & mask_mid2[15]);
    assign max1 = grp0_max1 | grp1_max1 | grp2_max1 | grp3_max1;

    assign mask1[0]  = mask_mid2[0]  & ~(r0[1]  ^ max1);
    assign mask1[1]  = mask_mid2[1]  & ~(r1[1]  ^ max1);
    assign mask1[2]  = mask_mid2[2]  & ~(r2[1]  ^ max1);
    assign mask1[3]  = mask_mid2[3]  & ~(r3[1]  ^ max1);
    assign mask1[4]  = mask_mid2[4]  & ~(r4[1]  ^ max1);
    assign mask1[5]  = mask_mid2[5]  & ~(r5[1]  ^ max1);
    assign mask1[6]  = mask_mid2[6]  & ~(r6[1]  ^ max1);
    assign mask1[7]  = mask_mid2[7]  & ~(r7[1]  ^ max1);
    assign mask1[8]  = mask_mid2[8]  & ~(r8[1]  ^ max1);
    assign mask1[9]  = mask_mid2[9]  & ~(r9[1]  ^ max1);
    assign mask1[10] = mask_mid2[10] & ~(r10[1] ^ max1);
    assign mask1[11] = mask_mid2[11] & ~(r11[1] ^ max1);
    assign mask1[12] = mask_mid2[12] & ~(r12[1] ^ max1);
    assign mask1[13] = mask_mid2[13] & ~(r13[1] ^ max1);
    assign mask1[14] = mask_mid2[14] & ~(r14[1] ^ max1);
    assign mask1[15] = mask_mid2[15] & ~(r15[1] ^ max1);

    // max0 分层 OR
    wire grp0_max0, grp1_max0, grp2_max0, grp3_max0;
    assign grp0_max0 = (r0[0] & mask1[0]) | (r1[0] & mask1[1]) | (r2[0] & mask1[2]) | (r3[0] & mask1[3]);
    assign grp1_max0 = (r4[0] & mask1[4]) | (r5[0] & mask1[5]) | (r6[0] & mask1[6]) | (r7[0] & mask1[7]);
    assign grp2_max0 = (r8[0] & mask1[8]) | (r9[0] & mask1[9]) | (r10[0] & mask1[10]) | (r11[0] & mask1[11]);
    assign grp3_max0 = (r12[0] & mask1[12]) | (r13[0] & mask1[13]) | (r14[0] & mask1[14]) | (r15[0] & mask1[15]);
    assign max0 = grp0_max0 | grp1_max0 | grp2_max0 | grp3_max0;

    // ────── 最终 max 输出（仅 PHASE3 有效） ──────
    wire [7:0] final_max;
    assign final_max = {max_high1, max_mid2, max1, max0};
    assign max_exp_o = (state == PHASE3) ? final_max : 8'b0;

    // ────── Delta Exponent 计算（组合逻辑，基于锁存的 r* 和 final_max） ──────
    wire [7:0] delta0, delta1, delta2, delta3, delta4, delta5, delta6, delta7,
               delta8, delta9, delta10, delta11, delta12, delta13, delta14, delta15;
    assign delta0  = final_max - r0;
    assign delta1  = final_max - r1;
    assign delta2  = final_max - r2;
    assign delta3  = final_max - r3;
    assign delta4  = final_max - r4;
    assign delta5  = final_max - r5;
    assign delta6  = final_max - r6;
    assign delta7  = final_max - r7;
    assign delta8  = final_max - r8;
    assign delta9  = final_max - r9;
    assign delta10 = final_max - r10;
    assign delta11 = final_max - r11;
    assign delta12 = final_max - r12;
    assign delta13 = final_max - r13;
    assign delta14 = final_max - r14;
    assign delta15 = final_max - r15;

    assign delta_exp_o = (state == PHASE3) ? { delta15, delta14, delta13, delta12, delta11, delta10,
                           delta9, delta8, delta7, delta6, delta5, delta4,
                           delta3, delta2, delta1, delta0 } : 128'b0;

    // ────── 握手信号 ──────
    assign data_vld_o = (state == PHASE3);
    assign data_rdy_o = (state == IDLE);

endmodule