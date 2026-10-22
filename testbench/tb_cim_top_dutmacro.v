`timescale 1ns/1ps
// =============================================================================
// Module : tb_cim_top
// Purpose: Self-checking testbench for cim_top.
//   - Drives the host SRAM-write interface to populate W and A SRAMs.
//   - Pulses start_i with batch_cnt / data_mode / start_addr.
//   - Captures posit_o on done_o and compares against a software reference.
//
// For pure RTL bring-up, this file can provide a simulation-only
// `posit_cim_storage_wrapper` behavioural stub when HAVE_REAL_RF_WRAPPER is
// NOT defined.  In the current posit_cim_28nm flow the real hand-written
// wrapper/RF should normally be compiled from RTL and the simulator should be
// invoked with +define+HAVE_REAL_RF_WRAPPER to suppress this stub.
//
// Test cases:
//   T1 : POSIT16, batch_cnt=1, all weights=1.0, all activations=1.0
//        -> Expected dot-product = 16.0 -> posit16 = 16'h6000
//   T2 : POSIT16, batch_cnt=2, all weights=1.0, all activations=1.0
//        -> Accumulator = 32.0 -> posit16 = 16'h6400
//   T3 : POSIT16, batch_cnt=1, mix of zero, NaR, +1, -1, maxpos, minpos
//        -> NaR/zero lanes contribute 0; rest sum normally.
//   T4 : POSIT16, batch_cnt=4, +1.0 / -1.0 alternating per batch
//        -> Final acc = 0 -> posit16 = 16'h0000
//   T5 : POSIT8 mode, batch_cnt=2, all 1.0 (=8'h40)
//        -> Each row holds 32 weights, but only 16 lanes per batch.
//        -> Two batches of 16x(1.0*1.0)=16.0 each -> sum=32.0
//        -> POSIT8 representation of 32.0 = 8'h64
// =============================================================================

// Clock period is intentionally configurable.  The port is still named
// clk_333MHz_i for RTL compatibility, but the actual period does not have to
// be 3 ns.  Override from VCS with, for example:
//   +define+CLK_PERIOD=2.8
// or directly:
//   +define+HALF_PERIOD=1.4
`ifndef HALF_PERIOD
  `ifdef CLK_PERIOD
    `define HALF_PERIOD (`CLK_PERIOD/2.0)
  `else
    `define HALF_PERIOD 1.4
  `endif
`endif

// -----------------------------------------------------------------------------
// Behavioural posit_cim_storage_wrapper for simulation only.
// 16-deep, 256-wide single-port; ce_n active-low, we_n active-low,
// 1-cycle synchronous read latency.  Matches the post-modification real
// macro (two 16x128 RF banks) -- only logical_addr[3:0] selects a row;
// upper bits are ignored exactly as the real wrapper does.
//
// Define `HAVE_REAL_SRAM_WRAPPER` on the simulator command line (e.g.
// `+define+HAVE_REAL_SRAM_WRAPPER`) to suppress this stub when the real
// MC2-generated wrapper is being elaborated.
// -----------------------------------------------------------------------------
`ifndef HAVE_REAL_RF_WRAPPER
module posit_cim_storage_wrapper (
    input  wire         clk,
    input  wire         ce_n,
    input  wire         we_n,
    input  wire [9:0]   logical_addr,
    input  wire [255:0] wdata,
    output reg  [255:0] rdata
);
    reg [255:0] mem [0:15];
    integer mi;
    initial begin
        for (mi = 0; mi < 16; mi = mi + 1) begin
            mem[mi] = 256'd0;
        end
        rdata = 256'd0;
    end

    always @(posedge clk) begin
        if (!ce_n) begin
            if (!we_n) begin
                mem[logical_addr[3:0]] <= wdata;
            end
            else begin
                rdata <= mem[logical_addr[3:0]];
            end
        end
    end
endmodule
`endif

// -----------------------------------------------------------------------------
// Testbench
// -----------------------------------------------------------------------------
module tb_cim_top;

    // ---- DUT parameters ---------------------------------------------------
    localparam SRAM_DATA_WIDTH = 256;
    // Matches the 16-deep posit_cim_storage_wrapper.  Every test below
    // keeps start_addr_i + batch_cnt_i bounded by 16, except T18 which
    // intentionally relies on the address counter's 4-bit wrap to exercise
    // a 64-batch run against pre-loaded duplicate data in addr 0..15.
    localparam SRAM_ADDR_WIDTH = 4;
    localparam BATCH_WIDTH     = 8;
    localparam EXP_WIDTH       = 8;
    localparam FRAC14          = 14;
    localparam FRAC28          = 28;
    localparam LANES           = 16;
    localparam RES_WIDTH       = 16;
    localparam POSIT16         = 1'b1;
    localparam POSIT8          = 1'b0;

    // ---- DUT I/O ----------------------------------------------------------
    reg                          clk_333MHz_i;
    reg                          rst_n_i;

    reg                          start_i;
    reg                          data_mode_i;
    reg  [BATCH_WIDTH-1:0]       batch_cnt_i;
    reg  [SRAM_ADDR_WIDTH-1:0]   start_addr_i;

    reg                          ext_we_n_i;
    reg                          ext_ce_n_i;
    reg  [SRAM_ADDR_WIDTH-1:0]   ext_addr_i;
    reg  [SRAM_DATA_WIDTH-1:0]   ext_w_data_i;
    reg  [SRAM_DATA_WIDTH-1:0]   ext_a_data_i;

    wire [RES_WIDTH-1:0]         posit_o;
    wire                         busy_o;
    wire                         done_o;

    // ---- Test bookkeeping -------------------------------------------------
    integer pass_cnt;
    integer fail_cnt;

    // ---- Real-workload (MNIST) hex-file backing storage -------------------
    // Enabled via `+define+MNIST_REAL_DATA` on the simulator command line.
    // The dump_mnist_hex C++ utility (alongside extract_distribution in
    // posit-neuralnet/examples/mnist_fcnn/src) emits five hex files per
    // regime:
    //
    //   <prefix>_w.hex             - 32 rows of 256-bit packed posits
    //   <prefix>_a.hex             - 32 rows of 256-bit packed posits
    //   <prefix>_expected.hex      - 8 entries (posit-encoded reference)
    //   <prefix>_expected_real.hex - 8 entries (IEEE 754 double bit
    //                                pattern; loaded with $bitstoreal)
    //   <prefix>_meta.hex          - 8 entries of 24-bit
    //                                {batch_cnt[7:0], 6'b0, addr_offset[9:0]}
    //
    // Three regimes are loaded:
    //   p16_l1 - posit<16,2>, layer 1 (linear1: 784 -> 32)
    //   p16_l2 - posit<16,2>, layer 2 (linear2: 32 -> 10, sigmoid input)
    //   p8_l1  - posit<8,2>,  layer 1, 32 lanes per SRAM row
    //
    // The MNIST block uses MSE on the *decoded real* values rather than a
    // strict bit-pattern match: the encoder may legitimately disagree with
    // the C++ reference by 1 LSB at tie-rounding boundaries, especially for
    // posit8 where the LSB step can be several percent.  See the
    // posit-decoder functions p16_to_real / p8_to_real below.
    `ifdef MNIST_REAL_DATA
    // posit16 layer-1
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l1_w   [0:15];
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l1_a   [0:15];
    reg [RES_WIDTH-1:0]       mnist_p16_l1_exp [0:7];
    reg [63:0]                mnist_p16_l1_real[0:7];
    reg [23:0]                mnist_p16_l1_meta[0:7];

    // posit16 layer-2
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l2_w   [0:15];
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l2_a   [0:15];
    reg [RES_WIDTH-1:0]       mnist_p16_l2_exp [0:7];
    reg [63:0]                mnist_p16_l2_real[0:7];
    reg [23:0]                mnist_p16_l2_meta[0:7];

    // posit8 layer-1
    reg [SRAM_DATA_WIDTH-1:0] mnist_p8_l1_w    [0:15];
    reg [SRAM_DATA_WIDTH-1:0] mnist_p8_l1_a    [0:15];
    reg [7:0]                 mnist_p8_l1_exp  [0:7];
    reg [63:0]                mnist_p8_l1_real [0:7];
    reg [23:0]                mnist_p8_l1_meta [0:7];

    // Real-valued accumulators for MSE.  Declared at module scope because
    // Verilog-2001 disallows `real` declarations in unnamed begin blocks.
    real mnist_sum_sq;
    real mnist_mse;
    real mnist_got_real;
    real mnist_exp_real;
    real mnist_diff_real;
    `endif


// DUT module name for gate-level simulation.
// Default is cim_top.  For ablation GLS, pass for example:
//   +define+DUT_TOP=cim_top_abl_mf
`ifndef DUT_TOP
  `define DUT_TOP cim_top
`endif

    // ---- DUT instance -----------------------------------------------------
`ifndef POST_SYN
    // RTL 仿真时，带有参数实例化
    cim_top #(
        .SRAM_DATA_WIDTH(SRAM_DATA_WIDTH),
        .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH),
        .BATCH_WIDTH    (BATCH_WIDTH),
        .EXP_WIDTH      (EXP_WIDTH),
        .FRAC14         (FRAC14),
        .FRAC28         (FRAC28),
        .LANES          (LANES),
        .RES_WIDTH      (RES_WIDTH),
        .POSIT16        (POSIT16),
        .POSIT8         (POSIT8)
    ) dut (
`else
    // 门级仿真 (GLS) 时，网表已被综合成固定顶层，禁止传递参数。
    // DUT_TOP 由 GLS 脚本注入：
    //   cim_top / cim_top_abl_mult / cim_top_abl_mf / cim_top_abl_dec
    `DUT_TOP dut (
`endif
        .clk_333MHz_i (clk_333MHz_i),
        .rst_n_i      (rst_n_i),
        .start_i      (start_i),
        .data_mode_i  (data_mode_i),
        .batch_cnt_i  (batch_cnt_i),
        .start_addr_i (start_addr_i),
        .ext_we_n_i   (ext_we_n_i),
        .ext_ce_n_i   (ext_ce_n_i),
        .ext_addr_i   (ext_addr_i),
        .ext_w_data_i (ext_w_data_i),
        .ext_a_data_i (ext_a_data_i),
        .posit_o      (posit_o),
        .busy_o       (busy_o),
        .done_o       (done_o)
    );

`ifdef POST_SYN
    initial begin : sdf_annotate_block
        // 使用编译时宏注入 (Compile-time Macro) 替代运行时的 $value$plusargs 传参。
        // 彻底解决 VCS 在 Elaboration 阶段因变量未初始化导致的 STASKEC_IFNSDFA 致命错误。
`ifdef SDF_PATH
        $sdf_annotate(`SDF_PATH, dut, , "sdf_annotate.log", "MAXIMUM");
`else
        // Default assumes the simulation is launched from
        // /path/to/projects/posit_cim_28nm/sim.
        // Corner-specific GLS scripts should override this with SDF_PATH.
        $sdf_annotate("../syn/outputs_ssg0p81vm40c/cim_top_ssg0p81vm40c.sdf",
                      dut, , "sdf_annotate.log", "MAXIMUM");
`endif
    end
`endif

    // ---- Clock & reset ----------------------------------------------------
    initial begin
        clk_333MHz_i = 1'b0;
        forever #(`HALF_PERIOD) clk_333MHz_i = ~clk_333MHz_i;
    end

    // ---- Constants for stimulus ------------------------------------------
    // POSIT16<es=2> encodings (computed by hand):
    //   0.0       = 16'h0000
    //   NaR       = 16'h8000
    //   +1.0      = 16'h4000
    //   -1.0      = 16'hC000
    //   maxpos    = 16'h7FFF
    //   minpos    = 16'h0001
    //   +2.0      = 16'h4400 (k=0, e=01, frac=0)
    //   -2.0      = 16'hBC00 (two's-complement of 0x4400)
    // POSIT8<es=2>:
    //   0.0       = 8'h00
    //   NaR       = 8'h80
    //   +1.0      = 8'h40
    //   -1.0      = 8'hC0
    //   maxpos    = 8'h7F
    //   minpos    = 8'h01

    // ---- Helper tasks ----------------------------------------------------
    task automatic do_reset;
        begin
            rst_n_i      = 1'b0;
            start_i      = 1'b0;
            data_mode_i  = POSIT16;
            batch_cnt_i  = 8'd0;
            start_addr_i = 4'd0;
            ext_we_n_i   = 1'b1;
            ext_ce_n_i   = 1'b1;
            ext_addr_i   = 4'd0;
            ext_w_data_i = 256'd0;
            ext_a_data_i = 256'd0;
            #(10*`HALF_PERIOD);
            @(negedge clk_333MHz_i);
            rst_n_i = 1'b1;
            #(2*`HALF_PERIOD);
`ifdef POST_SYN
            // After reset deasserts, gate-level flops can still hold X for
            // several cycles while the value settles through the pipeline.
            // Burn 20 idle cycles so the busy_o/done_o invariants checked
            // by run_mac fire on settled values rather than X.
            repeat (20) @(posedge clk_333MHz_i);
`endif
        end
    endtask

    // Write one 256-bit row each into W and A SRAMs at addr.
    task automatic sram_write;
        input [SRAM_ADDR_WIDTH-1:0] addr;
        input [SRAM_DATA_WIDTH-1:0] w_row;
        input [SRAM_DATA_WIDTH-1:0] a_row;
        begin
            @(negedge clk_333MHz_i);
            ext_ce_n_i   = 1'b0;
            ext_we_n_i   = 1'b0;
            ext_addr_i   = addr;
            ext_w_data_i = w_row;
            ext_a_data_i = a_row;
            @(negedge clk_333MHz_i);
            ext_ce_n_i   = 1'b1;
            ext_we_n_i   = 1'b1;
            ext_addr_i   = 4'd0;
            ext_w_data_i = 256'd0;
            ext_a_data_i = 256'd0;
        end
    endtask

    // Build a 256-bit row composed of 16x 16-bit POSIT values.
    function [255:0] pack16;
        input [15:0] v0,  v1,  v2,  v3,  v4,  v5,  v6,  v7;
        input [15:0] v8,  v9,  v10, v11, v12, v13, v14, v15;
        begin
            pack16 = {v15, v14, v13, v12, v11, v10, v9, v8,
                      v7,  v6,  v5,  v4,  v3,  v2,  v1, v0};
        end
    endfunction

    // Build a 256-bit row composed of 32x 8-bit POSIT values.
    function [255:0] pack32_8;
        input [7:0] v0 ,v1 ,v2 ,v3 ,v4 ,v5 ,v6 ,v7 ;
        input [7:0] v8 ,v9 ,v10,v11,v12,v13,v14,v15;
        input [7:0] v16,v17,v18,v19,v20,v21,v22,v23;
        input [7:0] v24,v25,v26,v27,v28,v29,v30,v31;
        begin
            pack32_8 = {v31,v30,v29,v28,v27,v26,v25,v24,
                        v23,v22,v21,v20,v19,v18,v17,v16,
                        v15,v14,v13,v12,v11,v10,v9 ,v8 ,
                        v7 ,v6 ,v5 ,v4 ,v3 ,v2 ,v1 ,v0 };
        end
    endfunction

    // Replicate a single 16-bit posit across all 16 lanes.
    function [255:0] rep16;
        input [15:0] v;
        begin
            rep16 = {16{v}};
        end
    endfunction

    // Replicate a single 8-bit posit across all 32 lanes.
    function [255:0] rep32_8;
        input [7:0] v;
        begin
            rep32_8 = {32{v}};
        end
    endfunction

    // Run one MAC operation and return posit_o on completion.  Also
    // sanity-checks the busy_o handshake protocol:
    //   * busy_o must be 0 just before start_i is asserted (idle).
    //   * busy_o must assert at least once between start_i and done_o
    //     (otherwise the controller never actually started working).
    //   * busy_o must be 0 again two cycles after done_o (back to idle).
    // Each violation increments fail_cnt independently of the result
    // comparison so protocol bugs are visible even when the data path
    // happens to produce the right answer.
    task automatic run_mac;
        input                       mode;
        input [BATCH_WIDTH-1:0]     bcnt;
        input [SRAM_ADDR_WIDTH-1:0] addr;
        output [RES_WIDTH-1:0]      result;
        integer timeout;
        integer busy_cycles;
        begin
            @(negedge clk_333MHz_i);
            if (busy_o !== 1'b0) begin
                $display("[TB] FAIL busy_o : asserted before start_i (busy=%b)", busy_o);
                fail_cnt = fail_cnt + 1;
            end
            data_mode_i  = mode;
            batch_cnt_i  = bcnt;
            start_addr_i = addr;
            start_i      = 1'b1;
            @(negedge clk_333MHz_i);
            start_i      = 1'b0;

            timeout = 0;
            busy_cycles = 0;
            while (!done_o && (timeout < 5000)) begin
                @(posedge clk_333MHz_i);
                if (busy_o) busy_cycles = busy_cycles + 1;
                timeout = timeout + 1;
            end
            if (!done_o) begin
                $display("[TB] ERROR: timeout waiting for done_o");
                result = 16'hxxxx;
            end
            else begin
                result = posit_o;
            end
            if (busy_cycles == 0) begin
                $display("[TB] FAIL busy_o : never asserted between start_i and done_o");
                fail_cnt = fail_cnt + 1;
            end
            @(negedge clk_333MHz_i);
            @(negedge clk_333MHz_i);
            if (busy_o !== 1'b0) begin
                $display("[TB] FAIL busy_o : still asserted after done_o (busy=%b)", busy_o);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Self-check helper.  Compares as raw 16-bit unsigned encodings; the
    // tolerance is in bit-encoding distance, NOT posit numeric distance.
    // Use tol=0 wherever the dot product is exactly representable in
    // posit16<es=2> (typically integer-valued sums of small powers of 2).
    task automatic check;
        input [255:0] tag;
        input [RES_WIDTH-1:0] got;
        input [RES_WIDTH-1:0] exp_val;
        input [RES_WIDTH-1:0] tol;        // |got - exp| <= tol counts as pass
        reg [RES_WIDTH-1:0] abs_diff;
        begin
            // Plain unsigned subtraction in the larger direction.  Both
            // inputs are 16-bit so |diff| < 2^16 and no widening is needed.
            abs_diff = (got >= exp_val) ? (got - exp_val) : (exp_val - got);
            if (abs_diff <= tol) begin
                pass_cnt = pass_cnt + 1;
                $display("[TB] PASS %0s : got=%h exp=%h (|diff|=%0d, tol=%0d)",
                         tag, got, exp_val, abs_diff, tol);
            end
            else begin
                fail_cnt = fail_cnt + 1;
                $display("[TB] FAIL %0s : got=%h exp=%h (|diff|=%0d, tol=%0d)",
                         tag, got, exp_val, abs_diff, tol);
            end
        end
    endtask

    // ----------------------------------------------------------------------
    // posit -> real decoders (used only by the MNIST_REAL_DATA MSE block).
    //
    // Each function:
    //   1. Treats 0x0000 (zero) and 0x_NaR_ (sign bit set, rest zero) as 0.
    //   2. Two's-complements the encoding when the sign bit is set so the
    //      remaining (nbits-1) "magnitude" bits can be parsed identically
    //      for positive and negative values.
    //   3. Decodes the regime as a run-length count of identical bits
    //      starting from the MSB of the magnitude.
    //   4. Reads the next es=2 bits as the exponent and the remainder as
    //      the fraction.
    //   5. Re-assembles value = sign * useed^k * 2^e * (1 + frac), with
    //      useed = 16 for es=2.
    //
    // Plain Verilog: no break statement, so the regime scan uses a "done"
    // sentinel.  Real arithmetic is supported in standard Verilog and is
    // simulation-only here.
    // ----------------------------------------------------------------------
    function real p16_to_real;
        input [15:0] bits;
        reg            sign;
        reg [14:0]     mag;
        integer        regime_run;
        integer        regime_field_len;
        integer        k;
        integer        e_val;
        integer        frac_pos;
        integer        frac_width;
        real           frac_val;
        real           useed_pow;
        integer        i;
        reg            done;
        begin
            // 0x0000 (zero) and 0x8000 (NaR) both have bits[14:0] == 0.
            if (bits[14:0] == 15'h0000) begin
                p16_to_real = 0.0;
            end
            else begin
                sign = bits[15];
                if (sign) mag = (~bits[14:0]) + 15'd1;
                else      mag = bits[14:0];

                done       = 1'b0;
                regime_run = 1;                          // bit 14 itself
                for (i = 13; i >= 0; i = i - 1) begin
                    if (!done) begin
                        if (mag[i] == mag[14])
                            regime_run = regime_run + 1;
                        else
                            done = 1'b1;
                    end
                end
                k                 = mag[14] ? (regime_run - 1) : -regime_run;
                regime_field_len  = done ? (regime_run + 1) : regime_run;

                e_val = 0;
                if (regime_field_len <= 13) begin
                    e_val = (mag[14 - regime_field_len] << 1)
                          |  mag[13 - regime_field_len];
                end
                else if (regime_field_len == 14) begin
                    e_val = (mag[0] << 1);                // only the high exp bit fits
                end

                frac_pos   = 12 - regime_field_len;
                frac_width = (frac_pos >= 0) ? (frac_pos + 1) : 0;
                frac_val   = 0.0;
                for (i = 0; i < frac_width; i = i + 1) begin
                    if (mag[frac_pos - i])
                        frac_val = frac_val + 1.0 / (1 << (i + 1));
                end

                useed_pow = 1.0;
                if (k >= 0) begin
                    for (i = 0; i < k; i = i + 1)
                        useed_pow = useed_pow * 16.0;
                end
                else begin
                    for (i = 0; i < -k; i = i + 1)
                        useed_pow = useed_pow / 16.0;
                end

                p16_to_real = (sign ? -1.0 : 1.0)
                              * useed_pow
                              * (1 << e_val)
                              * (1.0 + frac_val);
            end
        end
    endfunction

    function real p8_to_real;
        input [7:0]    bits;
        reg            sign;
        reg [6:0]      mag;
        integer        regime_run;
        integer        regime_field_len;
        integer        k;
        integer        e_val;
        integer        frac_pos;
        integer        frac_width;
        real           frac_val;
        real           useed_pow;
        integer        i;
        reg            done;
        begin
            if (bits[6:0] == 7'h00) begin
                p8_to_real = 0.0;
            end
            else begin
                sign = bits[7];
                if (sign) mag = (~bits[6:0]) + 7'd1;
                else      mag = bits[6:0];

                done       = 1'b0;
                regime_run = 1;
                for (i = 5; i >= 0; i = i - 1) begin
                    if (!done) begin
                        if (mag[i] == mag[6])
                            regime_run = regime_run + 1;
                        else
                            done = 1'b1;
                    end
                end
                k                = mag[6] ? (regime_run - 1) : -regime_run;
                regime_field_len = done ? (regime_run + 1) : regime_run;

                e_val = 0;
                if (regime_field_len <= 5) begin
                    e_val = (mag[6 - regime_field_len] << 1)
                          |  mag[5 - regime_field_len];
                end
                else if (regime_field_len == 6) begin
                    e_val = (mag[0] << 1);
                end

                frac_pos   = 4 - regime_field_len;
                frac_width = (frac_pos >= 0) ? (frac_pos + 1) : 0;
                frac_val   = 0.0;
                for (i = 0; i < frac_width; i = i + 1) begin
                    if (mag[frac_pos - i])
                        frac_val = frac_val + 1.0 / (1 << (i + 1));
                end

                useed_pow = 1.0;
                if (k >= 0) begin
                    for (i = 0; i < k; i = i + 1)
                        useed_pow = useed_pow * 16.0;
                end
                else begin
                    for (i = 0; i < -k; i = i + 1)
                        useed_pow = useed_pow / 16.0;
                end

                p8_to_real = (sign ? -1.0 : 1.0)
                             * useed_pow
                             * (1 << e_val)
                             * (1.0 + frac_val);
            end
        end
    endfunction

    // ---- Test scenarios --------------------------------------------------
    // POSIT16<es=2> constants (hand-derived, useed = 2^(2^2) = 16):
    //   +1.0  : k=0, e=0  -> 0_10_00_<11x0> = 0x4000
    //   +2.0  : k=0, e=1  -> 0_10_01_<11x0> = 0x4800
    //   +4.0  : k=0, e=2  -> 0_10_10_<11x0> = 0x5000
    //   +8.0  : k=0, e=3  -> 0_10_11_<11x0> = 0x5800
    //   +16.0 : k=1, e=0  -> 0_110_00_<10x0> = 0x6000
    //   +32.0 : k=1, e=1  -> 0_110_01_<10x0> = 0x6400
    //   +64.0 : k=1, e=2  -> 0_110_10_<10x0> = 0x6800
    //   +128.0: k=1, e=3  -> 0_110_11_<10x0> = 0x6C00
    //   -X    : two's complement of +X
    localparam [15:0] P16_ZERO   = 16'h0000;
    localparam [15:0] P16_NAR    = 16'h8000;
    localparam [15:0] P16_PONE   = 16'h4000;
    localparam [15:0] P16_NONE   = 16'hC000;
    localparam [15:0] P16_PTWO   = 16'h4800;
    localparam [15:0] P16_NTWO   = 16'hB800;
    localparam [15:0] P16_MAXPOS = 16'h7FFF;
    localparam [15:0] P16_MINPOS = 16'h0001;
    localparam [15:0] P16_4      = 16'h5000;
    localparam [15:0] P16_8      = 16'h5800;
    localparam [15:0] P16_16     = 16'h6000;
    localparam [15:0] P16_N16    = 16'hA000;   // -16.0
    localparam [15:0] P16_32     = 16'h6400;
    localparam [15:0] P16_64     = 16'h6800;
    localparam [15:0] P16_128    = 16'h6C00;
    localparam [15:0] P16_1024   = 16'h7400;   // +1024 = useed^2 * 2^2
    // +1.5 = useed^0 * 2^0 * (1+0.5); bits 0_10_00_<frac=10000000000>
    //      = 0100_0100_0000_0000 = 0x4400
    // NOTE: 0x4200 was wrong (= 1.25). Correct 1.5 = 0x4400.
    localparam [15:0] P16_1P5    = 16'h4400;
    // +36.0 = useed^1 * 2^1 * 1.125; bits 0_110_01_<frac=0010000000>
    //       = 0110_0100_1000_0000 = 0x6480
    localparam [15:0] P16_36     = 16'h6480;
    // 16 * minpos = useed^(-13). Posit16 representation:
    //   sign=0, regime "0_<13 zeros>_1" (14 bits), high exp bit 0, no frac
    //   bits: 0_00000000000001_0 = 0x0002
    localparam [15:0] P16_NXTMIN = 16'h0002;

    // ---- Expected sums for the heterogeneous-magnitude tests (T19-T23).
    // Each value is exactly representable in posit16<es=2>; the encoder
    // should produce these bit patterns with no rounding.
    //   T19 :   8 * 1 +   8 * 2 = 24      = 0x6200
    //   T20 :   4 *16 +  12 * 1 = 76      = 0x68C0
    //   T22 :   1 *64 +  15 * 1 = 79      = 0x68F0
    //   T23 :  2*(1+2+4+8+16+32+64+128) = 510 = 0x71FC
    // (T21 lands on +64 which already has a constant: P16_64.)
    localparam [15:0] P16_24     = 16'h6200;
    localparam [15:0] P16_76     = 16'h68C0;
    localparam [15:0] P16_79     = 16'h68F0;
    localparam [15:0] P16_510    = 16'h71FC;

    // POSIT8<es=2> constants:
    //   +1.0 : 0_10_00_000 = 0x40
    //   +2.0 : 0_10_01_000 = 0x48
    //   +16.0: 0_110_00_00 = 0x60
    //   +32.0: 0_110_01_00 = 0x64
    //   +64.0: 0_110_10_00 = 0x68
    localparam [7:0]  P8_ZERO = 8'h00;
    localparam [7:0]  P8_NAR  = 8'h80;
    localparam [7:0]  P8_PONE = 8'h40;
    localparam [7:0]  P8_NONE = 8'hC0;
    localparam [7:0]  P8_16   = 8'h60;
    localparam [7:0]  P8_32   = 8'h64;
    localparam [7:0]  P8_N32  = 8'h9C;        // -32.0 (two's complement of 0x64)
    localparam [7:0]  P8_64   = 8'h68;

    reg [RES_WIDTH-1:0] result_reg;
    integer             loop_i;
    reg                 dbg_en;

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        dbg_en   = 1'b0;

`ifdef VCD_PATH
        $dumpfile(`VCD_PATH);
`else
        // Default assumes the simulation is launched inside ./sim.
        $dumpfile("tb_cim_top.vcd");
`endif
        $dumpvars(0, tb_cim_top);

        do_reset;

        // -----------------------------------------------------------------
        // T1 : POSIT16, batch_cnt=1, all 1.0 x 1.0 -> 16.0
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_PONE), rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T1 P16 1.0*1.0 x16", result_reg, P16_16, 16'd2);

        // -----------------------------------------------------------------
        // T2 : POSIT16, batch_cnt=2, two batches each 1.0 x 1.0 -> 32.0
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_PONE), rep16(P16_PONE));
        sram_write(4'd1, rep16(P16_PONE), rep16(P16_PONE));
        run_mac(POSIT16, 8'd2, 4'd0, result_reg);
        check("T2 P16 acc 2x16.0", result_reg, P16_32, 16'd2);

        // -----------------------------------------------------------------
        // T3 : POSIT16, batch_cnt=1, mix of specials.
        //      lanes 0..3  : +1 * +1   = +1   (4 lanes -> +4.0)
        //      lanes 4..7  : NaR * +1  = 0    (treated as zero contribution)
        //      lanes 8..11 : 0 * +1    = 0
        //      lanes 12..15: -1 * +1   = -1   (4 lanes -> -4.0)
        //      Sum = 0.0
        // -----------------------------------------------------------------
        sram_write(4'd0,
            pack16(P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_NAR,  P16_NAR,  P16_NAR,  P16_NAR,
                   P16_ZERO, P16_ZERO, P16_ZERO, P16_ZERO,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE),
            rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T3 P16 specials sum=0", result_reg, P16_ZERO, 16'd2);

        // -----------------------------------------------------------------
        // T4 : POSIT16, 2 batches of +16.0 then -16.0  -> acc 0
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_PONE), rep16(P16_PONE));     // +16
        sram_write(4'd1, rep16(P16_NONE), rep16(P16_PONE));     // -16
        run_mac(POSIT16, 8'd2, 4'd0, result_reg);
        check("T4 P16 +16 + -16 = 0", result_reg, P16_ZERO, 16'd2);

        // -----------------------------------------------------------------
        // T5 : POSIT8 mode.
        //      Row holds 32 lanes worth of weights/activations; the macro
        //      folds it into two 16-lane batches so batch_cnt=2 consumes
        //      one SRAM row.  All P8_PONE -> dot product per batch = 16.0
        //      -> two batches accumulated = 32.0.
        //      Encoder yields posit8 result in posit_o[15:8].
        // -----------------------------------------------------------------
        sram_write(4'd0, rep32_8(P8_PONE), rep32_8(P8_PONE));
        run_mac(POSIT8, 8'd2, 4'd0, result_reg);
        check("T5 P8  acc 32.0", result_reg[15:8], P8_32, 8'd2);

        // -----------------------------------------------------------------
        // T6 : POSIT16, batch_cnt=1, all weights = 0.0, all activations = +1.0
        //      Every lane is_zero (E=8'h80, F=0) -> no contribution.
        //      Tests the "absorbed-as-zero" path for genuine zeros.
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_ZERO), rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T6 P16 all-zero W", result_reg, P16_ZERO, 16'd2);

        // -----------------------------------------------------------------
        // T7 : POSIT16, batch_cnt=1, all weights = NaR, all activations = +1.0
        //      NaR is treated identically to zero (E=8'h80, F=0) per spec
        //      Section 4.1; sum should be 0.
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_NAR), rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T7 P16 all-NaR W", result_reg, P16_ZERO, 16'd2);

        // -----------------------------------------------------------------
        // T8 : POSIT16, batch_cnt=8, eight batches each producing +16.0.
        //      Stresses the cross-batch wide accumulator (Q26.22) over a
        //      longer run.  Expected: 8 * 16.0 = 128.0 = 0x6C00.
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_PONE), rep16(P16_PONE));
        sram_write(4'd1, rep16(P16_PONE), rep16(P16_PONE));
        sram_write(4'd2, rep16(P16_PONE), rep16(P16_PONE));
        sram_write(4'd3, rep16(P16_PONE), rep16(P16_PONE));
        sram_write(4'd4, rep16(P16_PONE), rep16(P16_PONE));
        sram_write(4'd5, rep16(P16_PONE), rep16(P16_PONE));
        sram_write(4'd6, rep16(P16_PONE), rep16(P16_PONE));
        sram_write(4'd7, rep16(P16_PONE), rep16(P16_PONE));
        run_mac(POSIT16, 8'd8, 4'd0, result_reg);
        check("T8 P16 acc 8x16=128", result_reg, P16_128, 16'd4);

        // -----------------------------------------------------------------
        // T9 : POSIT16, batch_cnt=1, all weights = -1.0, all activations = +1.0
        //      Negative dot product = 16 * (-1.0) = -16.0.
        //      Verifies the negative-fraction encode path (sign extension,
        //      two's-complement assembly in the encoder).
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_NONE), rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T9 P16 -16.0", result_reg, P16_N16, 16'd2);

        // -----------------------------------------------------------------
        // T10: POSIT16, batch_cnt=1, only lane 0 contributes.
        //      Lane 0       : +1.0 * +1.0 = +1.0
        //      Lanes 1..15  : 0.0  * +1.0 = 0   (E=8'h80, F=0)
        //      Verifies that a single normal lane (alone against 15 special
        //      lanes) wins the TC-BWC-MF tournament correctly.  Result = 1.0.
        // -----------------------------------------------------------------
        sram_write(4'd0,
            pack16(P16_PONE, P16_ZERO, P16_ZERO, P16_ZERO,
                   P16_ZERO, P16_ZERO, P16_ZERO, P16_ZERO,
                   P16_ZERO, P16_ZERO, P16_ZERO, P16_ZERO,
                   P16_ZERO, P16_ZERO, P16_ZERO, P16_ZERO),
            rep16(P16_PONE));
        dbg_en = 1'b1;
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        dbg_en = 1'b0;
        check("T10 P16 single lane=1", result_reg, P16_PONE, 16'd2);

        // -----------------------------------------------------------------
        // T11: POSIT16, batch_cnt=2, batch 0 = +16.0, batch 1 mixed lanes.
        //      Batch 0: 16x +1*+1 = +16.0
        //      Batch 1:  8x +1*+1 + 8x -1*+1 = +8.0 - 8.0 = 0
        //      Total = +16.0.  Combines per-lane sign mix and cross-batch
        //      accumulation in a single test.
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_PONE), rep16(P16_PONE));
        sram_write(4'd1,
            pack16(P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE),
            rep16(P16_PONE));
        dbg_en = 1'b1;
        run_mac(POSIT16, 8'd2, 4'd0, result_reg);
        dbg_en = 1'b0;
        check("T11 P16 mixed batch", result_reg, P16_16, 16'd2);

        // -----------------------------------------------------------------
        // T12: POSIT8 mode, batch_cnt=2, all -1.0 * +1.0 -> -32.0.
        //      One SRAM row holds 32 lanes; macro folds into 2 batches each
        //      summing to -16.0.  Acc = -32.0; encoded posit8 = 0x9C.
        // -----------------------------------------------------------------
        sram_write(4'd0, rep32_8(P8_NONE), rep32_8(P8_PONE));
        run_mac(POSIT8, 8'd2, 4'd0, result_reg);
        check("T12 P8  acc -32.0", result_reg[15:8], P8_N32, 8'd2);

        // -----------------------------------------------------------------
        // T13: POSIT8 mode, batch_cnt=4, four batches of +16.0 -> +64.0.
        //      Two SRAM rows folded into 4 batches; stresses the POSIT8
        //      row-fold + cross-batch accumulator interaction.
        //      +64.0 in posit8 = 0x68.
        // -----------------------------------------------------------------
        sram_write(4'd0, rep32_8(P8_PONE), rep32_8(P8_PONE));
        sram_write(4'd1, rep32_8(P8_PONE), rep32_8(P8_PONE));
        run_mac(POSIT8, 8'd4, 4'd0, result_reg);
        check("T13 P8  acc 4x16=64", result_reg[15:8], P8_64, 8'd2);

        // -----------------------------------------------------------------
        // T14: POSIT16 back-to-back same-config repeat.
        //      Re-runs T1's setup at a different address to confirm the
        //      controller / encoder cleanly returns to IDLE between jobs.
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_PONE), rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T14 P16 b2b repeat",  result_reg, P16_16,   16'd2);

        // -----------------------------------------------------------------
        // T15: POSIT16, batch_cnt=1, all weights = +1.5, all activations = +1.5
        //      Per-lane product = 2.25; sum of 16 = 36.0 = 0x6480.
        //      Exercises the Booth encoder with a non-trivial mantissa
        //      (frac != 0): both PP6 and PP5 are non-zero per lane, so the
        //      msa_dcm cycles through is_zero = 4'b0xxx group.
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_1P5), rep16(P16_1P5));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T15 P16 1.5*1.5 x16=36", result_reg, P16_36, 16'd2);

        // -----------------------------------------------------------------
        // T16: POSIT16, batch_cnt=1, all weights = maxpos, all activations = +1.0
        //      Sum = 16 * maxpos = useed^15 -> overflows posit16 dynamic
        //      range -> encoder must saturate to maxpos = 0x7FFF.
        //      Verifies the regime_len >= max_width detector and the
        //      saturated_w mux in the encoder.
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_MAXPOS), rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T16 P16 maxpos sat", result_reg, P16_MAXPOS, 16'd0);

        // -----------------------------------------------------------------
        // T17: POSIT16, batch_cnt=1, all weights = minpos, all activations = +1.0
        //      Sum = 16 * minpos = useed^(-13).  This is one regime step
        //      above minpos and is exactly representable as 0x0002.
        //      Verifies the encoder's negative-regime + truncated-exp path
        //      (regime_len = 14, leaves only 1 bit room for exp).
        // -----------------------------------------------------------------
        sram_write(4'd0, rep16(P16_MINPOS), rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T17 P16 minpos x16", result_reg, P16_NXTMIN, 16'd1);

        // -----------------------------------------------------------------
        // T18: POSIT16, batch_cnt=64, sixty-four batches each = +16.0.
        //      With the 4-bit address counter the read sequence wraps every
        //      16 rows, so we only need to load the 16 physical rows once;
        //      the controller's address counter cycles through them four
        //      times.  Total = 64 * 16 = 1024.0 = 0x7400.  Stresses the
        //      Q26.22 cross-batch accumulator over a long run AND verifies
        //      the controller's wrap-around behaviour at addr 15 -> 0.
        // -----------------------------------------------------------------
        for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1) begin
            sram_write(loop_i[SRAM_ADDR_WIDTH-1:0],
                       rep16(P16_PONE), rep16(P16_PONE));
        end
        run_mac(POSIT16, 8'd64, 4'd0, result_reg);
        check("T18 P16 acc 64x16=1024", result_reg, P16_1024, 16'd2);

        // =================================================================
        // Heterogeneous-magnitude tests (T19-T23).
        //
        // The earlier suite drives every lane with the same posit value, so
        // every lane's delta_exp inside adder_tree is 0 and the per-lane
        // align-shifter is never exercised.  These five tests place posits
        // of differing exponents in the same vector to force non-zero
        // delta_exp on a subset of lanes.  Every result is an integer that
        // is exactly representable in posit16<es=2>, so tol=0 is correct.
        // =================================================================

        // T19: 8 lanes of +1.0 + 8 lanes of +2.0 (each * +1.0).
        //      Half the lanes have delta_exp=1, the rest 0.
        //      Sum = 8*1 + 8*2 = 24.0 = 0x6200.
        sram_write(4'd0,
            pack16(P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PTWO, P16_PTWO, P16_PTWO, P16_PTWO,
                   P16_PTWO, P16_PTWO, P16_PTWO, P16_PTWO),
            rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T19 P16 8x1+8x2=24",     result_reg, P16_24,  16'd0);

        // T20: 4 lanes of +16.0 + 12 lanes of +1.0 (each * +1.0).
        //      Wide split: 4 lanes get delta_exp=0, 12 get delta_exp=4.
        //      Sum = 4*16 + 12*1 = 76.0 = 0x68C0.
        sram_write(4'd0,
            pack16(P16_16,   P16_16,   P16_16,   P16_16,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE),
            rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T20 P16 4x16+12x1=76",   result_reg, P16_76,  16'd0);

        // T21: 4*+16 + 4*-1 + 4*+2 + 4*-1 (each * +1.0).
        //      Mixes per-lane sign AND magnitude in the same vector --
        //      negative lanes need both align-shift and two's-complement.
        //      Sum = 64 - 4 + 8 - 4 = 64.0 = 0x6800.
        sram_write(4'd0,
            pack16(P16_16,   P16_16,   P16_16,   P16_16,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE,
                   P16_PTWO, P16_PTWO, P16_PTWO, P16_PTWO,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE),
            rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T21 P16 mix sign+mag=64", result_reg, P16_64,  16'd0);

        // T22: 1 dominant lane (+64.0) + 15 small lanes (+1.0).
        //      Worst-case asymmetry: one lane at delta_exp=0, fifteen at
        //      delta_exp=6.  Verifies that small-magnitude lanes still
        //      contribute to the sum after a 6-bit arithmetic right shift
        //      rather than vanishing into rounding.
        //      Sum = 64 + 15 = 79.0 = 0x68F0.
        sram_write(4'd0,
            pack16(P16_64,   P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE),
            rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T22 P16 1x64+15x1=79",    result_reg, P16_79,  16'd0);

        // T23: every lane is a different magnitude.  Lanes 0..7 hold the
        //      powers of two from 1 to 128; lanes 8..15 repeat the same
        //      sequence.  The 16 lanes' delta_exp values sweep the full
        //      0..7 range -- the most exhaustive single-batch alignment
        //      stress in the suite, and the test that most directly
        //      exercises the rewritten align-shift logic in adder_tree.v.
        //      Sum = 2 * (1+2+4+...+128) = 510.0 = 0x71FC.
        sram_write(4'd0,
            pack16(P16_PONE, P16_PTWO, P16_4,    P16_8,
                   P16_16,   P16_32,   P16_64,   P16_128,
                   P16_PONE, P16_PTWO, P16_4,    P16_8,
                   P16_16,   P16_32,   P16_64,   P16_128),
            rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T23 P16 all-different=510", result_reg, P16_510, 16'd0);

        // =================================================================
        // Sequence / state-isolation tests (T24-T26).
        //
        // Verify that consecutive operations don't bleed state into each
        // other and that the controller can recover from a mid-flight
        // reset.
        // =================================================================

        // T24: P16 -> P8 -> P16 in rapid succession.  Each MAC uses
        //      different per-mode parameters so any stale folding /
        //      encoder-width state would corrupt the result.
        sram_write(4'd0, rep16  (P16_PONE), rep16  (P16_PONE));   // P16
        sram_write(4'd1, rep32_8(P8_PONE),  rep32_8(P8_PONE) );   // P8
        sram_write(4'd2, rep16  (P16_PTWO), rep16  (P16_PONE));   // P16
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T24a P16 first  =16",  result_reg,        P16_16, 16'd0);
        run_mac(POSIT8 , 8'd2, 4'd1, result_reg);
        check("T24b P8  middle =32",  result_reg[15:8],  P8_32,  8'd0);
        run_mac(POSIT16, 8'd1, 4'd2, result_reg);
        check("T24c P16 last   =32",  result_reg,        P16_32, 16'd0);

        // T25: assert reset partway through a 16-batch operation, then
        //      run a fresh 1-batch operation.  Confirms the controller
        //      and the cross-batch accumulator are fully cleared by the
        //      reset rather than leaking into the next job.
        for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1) begin
            sram_write(loop_i[SRAM_ADDR_WIDTH-1:0],
                       rep16(P16_PONE), rep16(P16_PONE));
        end
        @(negedge clk_333MHz_i);
        data_mode_i  = POSIT16;
        batch_cnt_i  = 8'd16;
        start_addr_i = 4'd0;
        start_i      = 1'b1;
        @(negedge clk_333MHz_i);
        start_i      = 1'b0;
        // Let the op run for ~30 cycles (well into the middle), then yank
        // the rug.  do_reset zeros all the testbench-driven inputs and
        // pulses rst_n_i low.
        repeat (30) @(posedge clk_333MHz_i);
        do_reset;
        sram_write(4'd0, rep16(P16_PONE), rep16(P16_PONE));
        run_mac(POSIT16, 8'd1, 4'd0, result_reg);
        check("T25 P16 post-reset =16", result_reg, P16_16, 16'd0);

        // T26: 5x repeat of an identical T1-style op.  If any per-op
        //      state (cross-batch accumulator, normalize stage, encoder
        //      pipeline) leaks, repeats will diverge.
        sram_write(4'd0, rep16(P16_PONE), rep16(P16_PONE));
        for (loop_i = 0; loop_i < 5; loop_i = loop_i + 1) begin
            run_mac(POSIT16, 8'd1, 4'd0, result_reg);
            check("T26 P16 repeat-isolation", result_reg, P16_16, 16'd0);
        end

        // =================================================================
        // Real-workload MNIST regression with MSE comparison (optional).
        //
        // Compile with `+define+MNIST_REAL_DATA`.  The C++ utility
        // `dump_mnist_hex` (in posit-neuralnet/examples/mnist_fcnn) emits
        // five hex files per regime into testdata/.  See the comment above
        // the array declarations near the top of the module for the
        // expected file layout.
        //
        // Why MSE rather than bit-exact: the encoder may legitimately
        // disagree with a software reference by 1 LSB at tie-rounding
        // boundaries, and posit8's LSB step can be a few percent of the
        // value.  Sum-of-squared real errors gives a single workload-level
        // accuracy metric that maps directly onto how an ML user would
        // judge "is the MAC unit accurate enough for inference".
        //
        // Threshold rationale:
        //   posit16  : LSB at value=0.5 is ~6e-5.  Per-op squared error
        //              up to a few LSB^2 -> ~4e-8 each, MSE ~ 4e-8.
        //              Use 1e-6 (allows ~10x slack vs typical rounding).
        //   posit8   : LSB at value=0.5 is ~3e-2.  Per-op squared error
        //              ~1e-3.  Use 1e-2 (room for posit8's coarse LSB).
        // =================================================================
`ifdef MNIST_REAL_DATA

        // ----- Regime 1: posit16 layer 1 -----
        $readmemh("testdata/p16_l1_w.hex",             mnist_p16_l1_w);
        $readmemh("testdata/p16_l1_a.hex",             mnist_p16_l1_a);
        $readmemh("testdata/p16_l1_expected.hex",      mnist_p16_l1_exp);
        $readmemh("testdata/p16_l1_expected_real.hex", mnist_p16_l1_real);
        $readmemh("testdata/p16_l1_meta.hex",          mnist_p16_l1_meta);

        for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1) begin
            sram_write(loop_i[SRAM_ADDR_WIDTH-1:0],
                       mnist_p16_l1_w[loop_i],
                       mnist_p16_l1_a[loop_i]);
        end
        mnist_sum_sq = 0.0;
        for (loop_i = 0; loop_i < 8; loop_i = loop_i + 1) begin
            run_mac(POSIT16,
                    mnist_p16_l1_meta[loop_i][23:16],
                    mnist_p16_l1_meta[loop_i][SRAM_ADDR_WIDTH-1:0],
                    result_reg);
            mnist_got_real  = p16_to_real(result_reg);
            mnist_exp_real  = $bitstoreal(mnist_p16_l1_real[loop_i]);
            mnist_diff_real = mnist_got_real - mnist_exp_real;
            mnist_sum_sq    = mnist_sum_sq + mnist_diff_real * mnist_diff_real;
            $display("[TB] p16_l1 op %0d : got=%h(%g) exp(%g) diff=%g",
                     loop_i, result_reg, mnist_got_real,
                     mnist_exp_real, mnist_diff_real);
        end
        mnist_mse = mnist_sum_sq / 8.0;
        if (mnist_mse <= 1.0e-6) begin
            pass_cnt = pass_cnt + 1;
            $display("[TB] PASS Tmnist p16_l1 MSE=%g (<=1e-6)", mnist_mse);
        end
        else begin
            fail_cnt = fail_cnt + 1;
            $display("[TB] FAIL Tmnist p16_l1 MSE=%g (>1e-6)", mnist_mse);
        end

        // ----- Regime 2: posit16 layer 2 -----
        $readmemh("testdata/p16_l2_w.hex",             mnist_p16_l2_w);
        $readmemh("testdata/p16_l2_a.hex",             mnist_p16_l2_a);
        $readmemh("testdata/p16_l2_expected.hex",      mnist_p16_l2_exp);
        $readmemh("testdata/p16_l2_expected_real.hex", mnist_p16_l2_real);
        $readmemh("testdata/p16_l2_meta.hex",          mnist_p16_l2_meta);

        for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1) begin
            sram_write(loop_i[SRAM_ADDR_WIDTH-1:0],
                       mnist_p16_l2_w[loop_i],
                       mnist_p16_l2_a[loop_i]);
        end
        mnist_sum_sq = 0.0;
        for (loop_i = 0; loop_i < 8; loop_i = loop_i + 1) begin
            run_mac(POSIT16,
                    mnist_p16_l2_meta[loop_i][23:16],
                    mnist_p16_l2_meta[loop_i][SRAM_ADDR_WIDTH-1:0],
                    result_reg);
            mnist_got_real  = p16_to_real(result_reg);
            mnist_exp_real  = $bitstoreal(mnist_p16_l2_real[loop_i]);
            mnist_diff_real = mnist_got_real - mnist_exp_real;
            mnist_sum_sq    = mnist_sum_sq + mnist_diff_real * mnist_diff_real;
            $display("[TB] p16_l2 op %0d : got=%h(%g) exp(%g) diff=%g",
                     loop_i, result_reg, mnist_got_real,
                     mnist_exp_real, mnist_diff_real);
        end
        mnist_mse = mnist_sum_sq / 8.0;
        if (mnist_mse <= 1.0e-6) begin
            pass_cnt = pass_cnt + 1;
            $display("[TB] PASS Tmnist p16_l2 MSE=%g (<=1e-6)", mnist_mse);
        end
        else begin
            fail_cnt = fail_cnt + 1;
            $display("[TB] FAIL Tmnist p16_l2 MSE=%g (>1e-6)", mnist_mse);
        end

        // ----- Regime 3: posit8 layer 1 -----
        $readmemh("testdata/p8_l1_w.hex",             mnist_p8_l1_w);
        $readmemh("testdata/p8_l1_a.hex",             mnist_p8_l1_a);
        $readmemh("testdata/p8_l1_expected.hex",      mnist_p8_l1_exp);
        $readmemh("testdata/p8_l1_expected_real.hex", mnist_p8_l1_real);
        $readmemh("testdata/p8_l1_meta.hex",          mnist_p8_l1_meta);

        // With the 16-deep SRAM there is no room for a separate p8 region
        // (the old `10'd700 + ...` offset is removed); each regime simply
        // overwrites the 16 rows in place.  Array bound matches the halved
        // generator (N_ROWS=16 in dump_mnist_hex.cpp).
        for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1) begin
            sram_write(loop_i[SRAM_ADDR_WIDTH-1:0],
                       mnist_p8_l1_w[loop_i],
                       mnist_p8_l1_a[loop_i]);
        end
        mnist_sum_sq = 0.0;
        for (loop_i = 0; loop_i < 8; loop_i = loop_i + 1) begin
            run_mac(POSIT8,
                    mnist_p8_l1_meta[loop_i][23:16],
                    mnist_p8_l1_meta[loop_i][SRAM_ADDR_WIDTH-1:0],
                    result_reg);
            // Posit8 result lands in posit_o[15:8] per cim_top spec.
            mnist_got_real  = p8_to_real(result_reg[15:8]);
            mnist_exp_real  = $bitstoreal(mnist_p8_l1_real[loop_i]);
            mnist_diff_real = mnist_got_real - mnist_exp_real;
            mnist_sum_sq    = mnist_sum_sq + mnist_diff_real * mnist_diff_real;
            $display("[TB] p8_l1  op %0d : got=%h(%g) exp(%g) diff=%g",
                     loop_i, result_reg[15:8], mnist_got_real,
                     mnist_exp_real, mnist_diff_real);
        end
        mnist_mse = mnist_sum_sq / 8.0;
        if (mnist_mse <= 1.0e-2) begin
            pass_cnt = pass_cnt + 1;
            $display("[TB] PASS Tmnist p8_l1  MSE=%g (<=1e-2)", mnist_mse);
        end
        else begin
            fail_cnt = fail_cnt + 1;
            $display("[TB] FAIL Tmnist p8_l1  MSE=%g (>1e-2)", mnist_mse);
        end
`endif

        // -----------------------------------------------------------------
        // Done.
        // -----------------------------------------------------------------
        $display("[TB] ===========================================");
        $display("[TB] Total: %0d passed, %0d failed",
                 pass_cnt, fail_cnt);
        $display("[TB] ===========================================");
        if (fail_cnt == 0) begin
            $display("[TB] OVERALL: PASS");
            $finish;
        end
        else begin
            $display("[TB] OVERALL: FAIL");
`ifdef TB_FATAL_ON_FAIL
            $fatal(1, "[TB] Testbench failed with %0d failures", fail_cnt);
`else
            $finish;
`endif
        end
    end

    // Watchdog
    initial begin
        #(500000);
        $display("[TB] FATAL: simulation watchdog expired");
        $finish;
    end

    // ---- Debug probes (encoder + adder_tree internals) ----------------
    // Reach into hierarchical signals to log per-batch values; gated by
    // dbg_en (declared with the other test-state regs above) which we
    // toggle around the test of interest so the log doesn't drown out the
    // pass/fail summary.
    //
    // Excluded from POST_SYN runs: synthesis flattens / renames internal
    // signals, so dut.u_enc.* and dut.u_at.* will fail to resolve against
    // the gate-level netlist.  Use the top-level ports (busy_o, done_o,
    // posit_o) for any debug visibility you still need post-syn.
`ifndef POST_SYN
    // Encoder batch-fire trace
    always @(posedge clk_333MHz_i) begin
        if (dbg_en && rst_n_i &&
            dut.u_enc.data_vld_i && dut.u_enc.data_rdy_o &&
            (dut.u_enc.state == 3'b000 /*IDLE*/)) begin
            $display("[DBG] BATCH_FIRE @%0t : f_new=%h e_new=%h | acc_F(prev)=%h acc_E(prev)=%h",
                     $time, dut.u_enc.frac_result_i, dut.u_enc.exp_result_i,
                     dut.u_enc.acc_F, dut.u_enc.acc_E);
        end
        if (dbg_en && rst_n_i && dut.u_enc.acc_done_i) begin
            $display("[DBG] ACC_DONE  @%0t : final acc_F=%h acc_E=%h",
                     $time, dut.u_enc.acc_F, dut.u_enc.acc_E);
        end
        if (dbg_en && rst_n_i && (dut.u_enc.state == 3'b001 /*NORM*/)) begin
            $display("[DBG] NORM     @%0t : abs_frac=%h lead_pos=%0d true_exp_w=%0d sign=%b",
                     $time, dut.u_enc.abs_frac_w, dut.u_enc.lead_pos,
                     $signed(dut.u_enc.true_exp_w), dut.u_enc.raw_sign);
        end
        // Adder tree result (tagged when its result_vld fires)
        if (dbg_en && rst_n_i && dut.u_at.result_vld_o) begin
            $display("[DBG] AT_RESULT @%0t : frac=%h exp=%h",
                     $time, dut.u_at.frac_result_o, dut.u_at.exp_result_o);
        end
    end
`endif

endmodule
