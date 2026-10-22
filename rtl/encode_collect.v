`timescale 1ns/1ps
module encode_collect #(
    parameter LANE_LENGTH = 16  ,
    parameter POSIT16     = 1'b1,
    parameter POSIT8      = 1'b0
)
(
    input  wire [4*LANE_LENGTH-1:0]  is_zero_i  ,
    input  wire                      data_mode_i,
    output wire [2:0]                cyc_avg_o
);

    wire [4*LANE_LENGTH-1:0] is_zero_rev;
    wire [2:0] c_lane_0;
    wire [2:0] c_lane_1;
    wire [2:0] c_lane_2;
    wire [2:0] c_lane_3;
    wire [2:0] c_lane_4;
    wire [2:0] c_lane_5;
    wire [2:0] c_lane_6;
    wire [2:0] c_lane_7;
    wire [2:0] c_lane_8;
    wire [2:0] c_lane_9;
    wire [2:0] c_lane_10;
    wire [2:0] c_lane_11;
    wire [2:0] c_lane_12;
    wire [2:0] c_lane_13;
    wire [2:0] c_lane_14;
    wire [2:0] c_lane_15;

    // 第一级树形加法：4 个组部分和（每组 4 个 lane）
    wire [4:0] sum_grp0;
    wire [4:0] sum_grp1;
    wire [4:0] sum_grp2;
    wire [4:0] sum_grp3;

    wire [6:0] cyc_sum;

    assign is_zero_rev = ~is_zero_i;

    // 每个 lane 的非零组个数（0~4）
    assign c_lane_0  = is_zero_rev[0]  + is_zero_rev[1]  + is_zero_rev[2]  + is_zero_rev[3];
    assign c_lane_1  = is_zero_rev[4]  + is_zero_rev[5]  + is_zero_rev[6]  + is_zero_rev[7];
    assign c_lane_2  = is_zero_rev[8]  + is_zero_rev[9]  + is_zero_rev[10] + is_zero_rev[11];
    assign c_lane_3  = is_zero_rev[12] + is_zero_rev[13] + is_zero_rev[14] + is_zero_rev[15];
    assign c_lane_4  = is_zero_rev[16] + is_zero_rev[17] + is_zero_rev[18] + is_zero_rev[19];
    assign c_lane_5  = is_zero_rev[20] + is_zero_rev[21] + is_zero_rev[22] + is_zero_rev[23];
    assign c_lane_6  = is_zero_rev[24] + is_zero_rev[25] + is_zero_rev[26] + is_zero_rev[27];
    assign c_lane_7  = is_zero_rev[28] + is_zero_rev[29] + is_zero_rev[30] + is_zero_rev[31];
    assign c_lane_8  = is_zero_rev[32] + is_zero_rev[33] + is_zero_rev[34] + is_zero_rev[35];
    assign c_lane_9  = is_zero_rev[36] + is_zero_rev[37] + is_zero_rev[38] + is_zero_rev[39];
    assign c_lane_10 = is_zero_rev[40] + is_zero_rev[41] + is_zero_rev[42] + is_zero_rev[43];
    assign c_lane_11 = is_zero_rev[44] + is_zero_rev[45] + is_zero_rev[46] + is_zero_rev[47];
    assign c_lane_12 = is_zero_rev[48] + is_zero_rev[49] + is_zero_rev[50] + is_zero_rev[51];
    assign c_lane_13 = is_zero_rev[52] + is_zero_rev[53] + is_zero_rev[54] + is_zero_rev[55];
    assign c_lane_14 = is_zero_rev[56] + is_zero_rev[57] + is_zero_rev[58] + is_zero_rev[59];
    assign c_lane_15 = is_zero_rev[60] + is_zero_rev[61] + is_zero_rev[62] + is_zero_rev[63];

    // 第一级树形求和：4 个 lane 为一组相加，得 5 位部分和
    assign sum_grp0 = {2'b0, c_lane_0}  + {2'b0, c_lane_1}  + {2'b0, c_lane_2}  + {2'b0, c_lane_3};
    assign sum_grp1 = {2'b0, c_lane_4}  + {2'b0, c_lane_5}  + {2'b0, c_lane_6}  + {2'b0, c_lane_7};
    assign sum_grp2 = {2'b0, c_lane_8}  + {2'b0, c_lane_9}  + {2'b0, c_lane_10} + {2'b0, c_lane_11};
    assign sum_grp3 = {2'b0, c_lane_12} + {2'b0, c_lane_13} + {2'b0, c_lane_14} + {2'b0, c_lane_15};

    // 第二级树形求和：4 个组部分和相加，得 7 位总和
    assign cyc_sum = {2'b0, sum_grp0} + {2'b0, sum_grp1} + {2'b0, sum_grp2} + {2'b0, sum_grp3};

    // floor 平均：除以 16（右移 4 位）
    assign cyc_avg_o = (data_mode_i == POSIT16) ? cyc_sum[6:4] : (cyc_sum[6:4] + |cyc_sum[3:0]);

endmodule




