`timescale 1ns/1ps

// =============================================================================
// Module Name: posit_encoder
// Description: High-Performance, Combinational LZD based POSIT Encoding Unit.
//              Strictly follows: One-variable-per-always-block, No 2D arrays, 
//              No generate-for loops. Fixed 3-cycle processing latency.
// =============================================================================

module posit_encoder #(
    parameter RES_WIDTH  =     16,
    parameter ES         =      2,
    parameter EXP_WIDTH  =      8,
    parameter FRAC_WIDTH =     32,
    parameter SIGN_WIDTH =      1,
    parameter IDLE       =  2'b00,
    parameter NORM       =  2'b01,
    parameter CALC       =  2'b10,
    parameter DONE       =  2'b11,
    parameter POSIT16    =      1,
    parameter POSIT8     =      0
)
(
    input  wire                   clk_333MHz_i,
    input  wire                        rst_n_i,
    input  wire [FRAC_WIDTH-1:0] frac_result_i,
    input  wire [EXP_WIDTH-1:0]   exp_result_i,
    input  wire                     data_vld_i,
    input  wire                     data_rdy_i,
    input  wire                    data_mode_i,
    output wire [RES_WIDTH-1:0]        posit_o,
    output wire                     data_vld_o,
    output wire                     data_rdy_o
);

    // =========================================================================
    // 状态机寄存器与变量
    // =========================================================================
    reg [1:0] state;

    // Stage 1 Registers (IDLE -> NORM)
    reg [31:0] raw_frac;
    reg [7:0]  raw_exp;

    // Stage 2 Registers (NORM -> CALC)
    reg [31:0] norm_frac;
    reg [8:0]  true_exp;
    reg        sign_reg;
    reg        is_zero_reg;

    // Stage 3 Registers (CALC -> DONE)
    reg [15:0] final_posit;

    // =========================================================================
    // 组合逻辑 Stage 1: 绝对值提取与单周期前导一检测 (Combinational LZD)
    // =========================================================================
    wire        raw_sign   = raw_frac[31];
    wire [31:0] abs_frac_w = raw_sign ? (~raw_frac + 32'd1) : raw_frac;
    
    // 无循环的硬编码优先编码器 (综合工具会优化为极速树状结构)
    reg [4:0] lead_pos;
    always @* begin
        if      (abs_frac_w[30]) lead_pos = 5'd30;
        else if (abs_frac_w[29]) lead_pos = 5'd29;
        else if (abs_frac_w[28]) lead_pos = 5'd28;
        else if (abs_frac_w[27]) lead_pos = 5'd27;
        else if (abs_frac_w[26]) lead_pos = 5'd26;
        else if (abs_frac_w[25]) lead_pos = 5'd25;
        else if (abs_frac_w[24]) lead_pos = 5'd24;
        else if (abs_frac_w[23]) lead_pos = 5'd23;
        else if (abs_frac_w[22]) lead_pos = 5'd22;
        else if (abs_frac_w[21]) lead_pos = 5'd21;
        else if (abs_frac_w[20]) lead_pos = 5'd20;
        else if (abs_frac_w[19]) lead_pos = 5'd19;
        else if (abs_frac_w[18]) lead_pos = 5'd18;
        else if (abs_frac_w[17]) lead_pos = 5'd17;
        else if (abs_frac_w[16]) lead_pos = 5'd16;
        else if (abs_frac_w[15]) lead_pos = 5'd15;
        else if (abs_frac_w[14]) lead_pos = 5'd14;
        else if (abs_frac_w[13]) lead_pos = 5'd13;
        else if (abs_frac_w[12]) lead_pos = 5'd12;
        else if (abs_frac_w[11]) lead_pos = 5'd11;
        else if (abs_frac_w[10]) lead_pos = 5'd10;
        else if (abs_frac_w[ 9]) lead_pos = 5'd9;
        else if (abs_frac_w[ 8]) lead_pos = 5'd8;
        else if (abs_frac_w[ 7]) lead_pos = 5'd7;
        else if (abs_frac_w[ 6]) lead_pos = 5'd6;
        else if (abs_frac_w[ 5]) lead_pos = 5'd5;
        else if (abs_frac_w[ 4]) lead_pos = 5'd4;
        else if (abs_frac_w[ 3]) lead_pos = 5'd3;
        else if (abs_frac_w[ 2]) lead_pos = 5'd2;
        else if (abs_frac_w[ 1]) lead_pos = 5'd1;
        else if (abs_frac_w[ 0]) lead_pos = 5'd0;
        else                     lead_pos = 5'd0;
    end

    wire is_zero_w = (abs_frac_w[30:0] == 31'd0);

    // 桶形移位器 (Barrel Shifter): 强行将最高有效位推至 bit 30
    wire [31:0] norm_frac_w = abs_frac_w << (5'd30 - lead_pos);

    // 阶码补偿: 输入是 Q10.22 定点数，隐含小数点在 bit 22。
    // 如果前导 1 恰好在 bit 22，则代表 1.x * 2^0，阶码不用变。
    // 每偏高一位 (如 bit 23)，代表数值大一倍，阶码 +1。
    wire signed [8:0] true_exp_w = $signed(raw_exp) + $signed({1'b0, lead_pos}) - 9'd22;

    // =========================================================================
    // 组合逻辑 Stage 2: POSIT 掩码拼装与舍入 (Mask Assembly & Rounding)
    // =========================================================================
    wire signed [8:0] E = true_exp;
    wire signed [6:0] k = E[8:2]; // 等价于 floor(E/4)
    wire [1:0]        e = E[1:0];

    wire       regime_bit   = (E[8] == 1'b0); // k >= 0 则为 1
    wire [6:0] abs_k        = regime_bit ? k : (~k + 7'd1);
    wire [6:0] regime_len_w = regime_bit ? (abs_k + 7'd2) : (abs_k + 7'd1);

    // 组装前 31 位的基础数据块 (Exponent | Fraction)
    wire [30:0] exp_frac_31 = {e, norm_frac[29:1]};
    
    // 安全移位: 限制最大移位量，防止越界
    wire [4:0]  shift_amt   = (regime_len_w >= 7'd31) ? 5'd31 : regime_len_w[4:0];
    wire [30:0] shifted_ef  = exp_frac_31 >> shift_amt;

    // 无循环生成变长 Regime 序列
    wire [30:0] ones_mask  = ~(31'h7FFFFFFF >> shift_amt);
    wire [30:0] term_bit   = 31'd1 << (5'd31 - shift_amt);
    wire [30:0] regime_str = regime_bit ? (ones_mask ^ term_bit) : term_bit;

    // 合并生成绝对值正数 POSIT 位流 (此时 Sign 强制为 0)
    wire [31:0] assembled_pos_w = {1'b0, (regime_str | shifted_ef)};

    // --- GRS 舍入逻辑 ---
    wire posit_lsb = (data_mode_i == POSIT16) ? assembled_pos_w[16] : assembled_pos_w[24];
    wire guard     = (data_mode_i == POSIT16) ? assembled_pos_w[15] : assembled_pos_w[23];
    wire round_b   = (data_mode_i == POSIT16) ? assembled_pos_w[14] : assembled_pos_w[22];
    wire sticky    = (data_mode_i == POSIT16) ? (|assembled_pos_w[13:0]) : (|assembled_pos_w[21:0]);

    wire round_up  = guard & (round_b | sticky | posit_lsb);

    wire [15:0] unrounded_16 = assembled_pos_w[31:16];
    wire [7:0]  unrounded_8  = assembled_pos_w[31:24];

    wire [15:0] rounded_pos_16 = unrounded_16 + {15'd0, round_up};
    wire [7:0]  rounded_pos_8  = unrounded_8  + {7'd0, round_up};

    // --- 负数补码还原与饱和截断 ---
    // 巧妙利用：正数补码是其本身，负数的 -X = ~X + 1。
    wire [15:0] final_val_16 = sign_reg ? (~rounded_pos_16 + 16'd1) : rounded_pos_16;
    wire [7:0]  final_val_8  = sign_reg ? (~rounded_pos_8  + 8'd1)  : rounded_pos_8;

    wire [6:0] max_width = (data_mode_i == POSIT16) ? 7'd16 : 7'd8;
    wire       is_ovf_w  = (regime_len_w >= max_width);

    wire [15:0] final_posit_w = is_zero_reg ? 16'd0 :
                                is_ovf_w ? (data_mode_i == POSIT16 ? (sign_reg ? 16'h8001 : 16'h7FFF) : 
                                                                     (sign_reg ? 16'h8100 : 16'h7F00)) :
                                (data_mode_i == POSIT16 ? final_val_16 : {final_val_8, 8'd0});

    // =========================================================================
    // 严格的时序逻辑 (1个 always 块只分配 1个变量)
    // =========================================================================

    // 1. 状态机
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: begin 
                    if (data_vld_i & data_rdy_o) state <= NORM;
                    else state <= IDLE;
                end
                NORM: state <= CALC;
                CALC: state <= DONE;
                DONE: begin
                    if (data_rdy_i & data_vld_o) state <= IDLE;
                    else state <= DONE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    // 2. Latch Raw Fraction
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) raw_frac <= 32'd0;
        else if (state == IDLE && data_vld_i && data_rdy_o) raw_frac <= frac_result_i;
        else raw_frac <= raw_frac;
    end

    // 3. Latch Raw Exponent
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) raw_exp <= 8'd0;
        else if (state == IDLE && data_vld_i && data_rdy_o) raw_exp <= exp_result_i;
        else raw_exp <= raw_exp;
    end

    // 4. Latch Normalized Fraction
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) norm_frac <= 32'd0;
        else if (state == NORM) norm_frac <= norm_frac_w;
        else norm_frac <= norm_frac;
    end

    // 5. Latch True Exponent
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) true_exp <= 9'd0;
        else if (state == NORM) true_exp <= true_exp_w;
        else true_exp <= true_exp;
    end

    // 6. Latch Sign Flag
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) sign_reg <= 1'b0;
        else if (state == NORM) sign_reg <= raw_sign;
        else sign_reg <= sign_reg;
    end

    // 7. Latch Zero Flag
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) is_zero_reg <= 1'b0;
        else if (state == NORM) is_zero_reg <= is_zero_w;
        else is_zero_reg <= is_zero_reg;
    end

    // 8. Latch Final Posit
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) final_posit <= 16'd0;
        else if (state == CALC) final_posit <= final_posit_w;
        else final_posit <= final_posit;
    end

    // =========================================================================
    // 接口输出分配
    // =========================================================================
    assign data_vld_o = (state == DONE);
    assign data_rdy_o = (state == IDLE);
    assign posit_o    = final_posit;

endmodule