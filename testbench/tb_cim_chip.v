`timescale 1ns/1ps
// =============================================================================
// Module : tb_cim_chip
// Purpose: Self-checking chip-level testbench for cim_chip.
//
//   Every interaction with the DUT goes through the host register bus
//   (host_req / host_we / host_addr / host_wdata / host_rdata / host_ack).
//   All 26 hand-crafted T1-T26 cases and the 3-regime MNIST MSE regression
//   from tb_cim_top.v are preserved; tests with no inter-op state are
//   distributed across N_CIM cores so they run in parallel.
//
//   Mapping (N_CIM=16 by default):
//     Batch B1 (parallel, 16 cores)  T1..T16
//     Batch B2 (parallel, 7 cores)   T17, T18, T19, T20, T21, T22, T23
//     Sequential on core 0           T24 (P16 -> P8 -> P16 on same core)
//     Sequential on core 0           T26 (5x repeat-isolation)
//     Standalone, global reset       T25 (mid-flight reset)
//     MNIST p16_l1 (parallel, 8 cores)  8 ops via cores 0..7
//     MNIST p16_l2 (parallel, 8 cores)  8 ops via cores 0..7
//     MNIST p8_l1  (parallel, 8 cores)  8 ops via cores 0..7
//
// Compile-time switches (same as tb_cim_top.v):
//   POST_SYN               $sdf_annotate at time 0; X-flush after reset
//   HAVE_REAL_RF_WRAPPER   suppress behavioral RF/storage wrapper stub
//   MNIST_REAL_DATA        load testdata/*.hex and run MSE regression
//   CLK_PERIOD             optional full clock period in ns for TB clock generation
//   VCD_PATH               optional VCD output path
//   TB_FATAL_ON_FAIL       optional non-zero simulator exit when any test fails
// =============================================================================

// Default TB clock period is 3.0 ns. For RTL behavioral simulation this only
// controls simulation pacing; timing closure is verified by SDC + SDF/GLS.
`ifndef CLK_PERIOD
`define CLK_PERIOD 3.0
`endif

`define HALF_PERIOD (`CLK_PERIOD/2.0)

// -----------------------------------------------------------------------------
// Behavioural SRAM stub (16-deep, 256-wide) - same as tb_cim_top.v.
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
        for (mi = 0; mi < 16; mi = mi + 1) mem[mi] = 256'd0;
        rdata = 256'd0;
    end
    always @(posedge clk) begin
        if (!ce_n) begin
            if (!we_n) mem[logical_addr[3:0]] <= wdata;
            else       rdata <= mem[logical_addr[3:0]];
        end
    end
endmodule
`endif

// -----------------------------------------------------------------------------
// Testbench
// -----------------------------------------------------------------------------
module tb_cim_chip;

    // ---- DUT parameters --------------------------------------------------
    localparam N_CIM           = 16;
    localparam SRAM_DATA_WIDTH = 256;
    localparam SRAM_ADDR_WIDTH = 4;
    localparam BATCH_WIDTH     = 8;
    localparam EXP_WIDTH       = 8;
    localparam FRAC14          = 14;
    localparam FRAC28          = 28;
    localparam LANES           = 16;
    localparam RES_WIDTH       = 16;
    localparam POSIT16         = 1'b1;
    localparam POSIT8          = 1'b0;
    localparam HOST_ADDR_WIDTH = 16;
    localparam HOST_DATA_WIDTH = 256;

    // ---- DUT I/O ---------------------------------------------------------
    reg                          clk_333MHz_i;
    reg                          rst_n_i;
    reg                          host_req_i;
    reg                          host_we_i;
    reg  [HOST_ADDR_WIDTH-1:0]   host_addr_i;
    reg  [HOST_DATA_WIDTH-1:0]   host_wdata_i;
    wire [HOST_DATA_WIDTH-1:0]   host_rdata_o;
    wire                         host_ack_o;
    wire                         busy_any_o;
    wire                         done_all_o;

    // ---- Test bookkeeping ------------------------------------------------
    integer pass_cnt;
    integer fail_cnt;

    // ---- MNIST hex backing storage (guarded) ----------------------------
    `ifdef MNIST_REAL_DATA
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l1_w   [0:15];
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l1_a   [0:15];
    reg [RES_WIDTH-1:0]       mnist_p16_l1_exp [0:7];
    reg [63:0]                mnist_p16_l1_real[0:7];
    reg [23:0]                mnist_p16_l1_meta[0:7];

    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l2_w   [0:15];
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l2_a   [0:15];
    reg [RES_WIDTH-1:0]       mnist_p16_l2_exp [0:7];
    reg [63:0]                mnist_p16_l2_real[0:7];
    reg [23:0]                mnist_p16_l2_meta[0:7];

    reg [SRAM_DATA_WIDTH-1:0] mnist_p8_l1_w    [0:15];
    reg [SRAM_DATA_WIDTH-1:0] mnist_p8_l1_a    [0:15];
    reg [7:0]                 mnist_p8_l1_exp  [0:7];
    reg [63:0]                mnist_p8_l1_real [0:7];
    reg [23:0]                mnist_p8_l1_meta [0:7];

    real mnist_sum_sq;
    real mnist_mse;
    real mnist_got_real;
    real mnist_exp_real;
    real mnist_diff_real;
    `endif

    // ---- DUT instance ----------------------------------------------------
`ifndef POST_SYN
    cim_chip #(
        .N_CIM           (N_CIM),
        .SRAM_DATA_WIDTH (SRAM_DATA_WIDTH),
        .SRAM_ADDR_WIDTH (SRAM_ADDR_WIDTH),
        .BATCH_WIDTH     (BATCH_WIDTH),
        .EXP_WIDTH       (EXP_WIDTH),
        .FRAC14          (FRAC14),
        .FRAC28          (FRAC28),
        .LANES           (LANES),
        .RES_WIDTH       (RES_WIDTH),
        .POSIT16         (POSIT16),
        .POSIT8          (POSIT8),
        .HOST_ADDR_WIDTH (HOST_ADDR_WIDTH),
        .HOST_DATA_WIDTH (HOST_DATA_WIDTH)
    ) dut (
`else
    cim_chip dut (
`endif
        .clk_333MHz_i (clk_333MHz_i),
        .rst_n_i      (rst_n_i),
        .host_req_i   (host_req_i),
        .host_we_i    (host_we_i),
        .host_addr_i  (host_addr_i),
        .host_wdata_i (host_wdata_i),
        .host_rdata_o (host_rdata_o),
        .host_ack_o   (host_ack_o),
        .busy_any_o   (busy_any_o),
        .done_all_o   (done_all_o)
    );

`ifdef POST_SYN
    initial begin : sdf_annotate_block
`ifdef SDF_PATH
        $sdf_annotate(`SDF_PATH, dut, , "sdf_annotate.log", "MAXIMUM");
`else
        $sdf_annotate("../syn/outputs_chip_tt_0p90v_0p90v_25c/cim_chip_tt_0p90v_0p90v_25c.sdf",
                      dut, , "sdf_annotate.log", "MAXIMUM");
`endif
    end
`endif

    // ---- Clock -----------------------------------------------------------
    initial begin
        clk_333MHz_i = 1'b0;
        forever #(`HALF_PERIOD) clk_333MHz_i = ~clk_333MHz_i;
    end

    // =====================================================================
    // Address-map helpers and host-bus driver tasks
    // =====================================================================
    function [HOST_ADDR_WIDTH-1:0] addr_shadow_w;
        input [5:0] core_id;
        addr_shadow_w = {4'h0, core_id, 6'h00};
    endfunction
    function [HOST_ADDR_WIDTH-1:0] addr_commit_a;
        input [5:0] core_id;
        input [3:0] row;
        addr_commit_a = {4'h1, core_id, 2'b00, row};
    endfunction
    function [HOST_ADDR_WIDTH-1:0] addr_cfg;
        input [5:0] core_id;
        addr_cfg = {4'h2, core_id, 6'h00};
    endfunction
    function [HOST_ADDR_WIDTH-1:0] addr_result;
        input [5:0] core_id;
        addr_result = {4'h3, core_id, 6'h00};
    endfunction
    localparam [HOST_ADDR_WIDTH-1:0] ADDR_LAUNCH    = {4'h8, 12'h000};
    localparam [HOST_ADDR_WIDTH-1:0] ADDR_GBL_STAT  = {4'h9, 12'h000};
    localparam [HOST_ADDR_WIDTH-1:0] ADDR_CLEAR_DN  = {4'hA, 12'h000};

    task automatic bus_write;
        input [HOST_ADDR_WIDTH-1:0] addr;
        input [HOST_DATA_WIDTH-1:0] data;
        begin
            @(negedge clk_333MHz_i);
            host_req_i   = 1'b1;
            host_we_i    = 1'b1;
            host_addr_i  = addr;
            host_wdata_i = data;
            @(negedge clk_333MHz_i);
            host_req_i   = 1'b0;
            host_we_i    = 1'b0;
            host_addr_i  = {HOST_ADDR_WIDTH{1'b0}};
            host_wdata_i = {HOST_DATA_WIDTH{1'b0}};
        end
    endtask

    task automatic bus_read;
        input  [HOST_ADDR_WIDTH-1:0] addr;
        output [HOST_DATA_WIDTH-1:0] data;
        begin
            @(negedge clk_333MHz_i);
            host_req_i   = 1'b1;
            host_we_i    = 1'b0;
            host_addr_i  = addr;
            host_wdata_i = {HOST_DATA_WIDTH{1'b0}};
            @(negedge clk_333MHz_i);
            host_req_i   = 1'b0;
            host_addr_i  = {HOST_ADDR_WIDTH{1'b0}};
            data         = host_rdata_o;
        end
    endtask

    task automatic core_load_row;
        input [5:0]   core_id;
        input [3:0]   row;
        input [255:0] w_row;
        input [255:0] a_row;
        begin
            bus_write(addr_shadow_w(core_id), w_row);
            bus_write(addr_commit_a(core_id, row), a_row);
        end
    endtask

    task automatic core_cfg;
        input [5:0] core_id;
        input       data_mode;
        input [3:0] start_addr;
        input [7:0] batch_cnt;
        reg [HOST_DATA_WIDTH-1:0] cfg_word;
        begin
            cfg_word = {{(HOST_DATA_WIDTH-13){1'b0}}, data_mode, start_addr, batch_cnt};
            bus_write(addr_cfg(core_id), cfg_word);
        end
    endtask

    task automatic launch_mask;
        input [N_CIM-1:0] mask;
        begin
            bus_write(ADDR_LAUNCH,
                      {{(HOST_DATA_WIDTH-N_CIM){1'b0}}, mask});
        end
    endtask

    task automatic clear_done;
        input [N_CIM-1:0] mask;
        begin
            bus_write(ADDR_CLEAR_DN,
                      {{(HOST_DATA_WIDTH-N_CIM){1'b0}}, mask});
        end
    endtask

    task automatic wait_mask_done;
        input [N_CIM-1:0] mask;
        integer timeout;
        reg [HOST_DATA_WIDTH-1:0] rd;
        reg [N_CIM-1:0] dl;
        begin
            timeout = 0;
            dl      = {N_CIM{1'b0}};
            while (((dl & mask) != mask) && (timeout < 20000)) begin
                bus_read(ADDR_GBL_STAT, rd);
                dl = rd[N_CIM +: N_CIM];
                timeout = timeout + 1;
            end
            if ((dl & mask) != mask) begin
                $display("[TB] TIMEOUT waiting for done mask=%h, got dl=%h",
                         mask, dl);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task automatic core_read_result;
        input  [5:0]            core_id;
        output [RES_WIDTH-1:0]  result;
        reg    [HOST_DATA_WIDTH-1:0] rd;
        begin
            bus_read(addr_result(core_id), rd);
            result = rd[RES_WIDTH-1:0];
        end
    endtask

    task automatic do_reset;
        begin
            rst_n_i      = 1'b0;
            host_req_i   = 1'b0;
            host_we_i    = 1'b0;
            host_addr_i  = {HOST_ADDR_WIDTH{1'b0}};
            host_wdata_i = {HOST_DATA_WIDTH{1'b0}};
            #(10*`HALF_PERIOD);
            @(negedge clk_333MHz_i);
            rst_n_i = 1'b1;
            #(2*`HALF_PERIOD);
`ifdef POST_SYN
            repeat (20) @(posedge clk_333MHz_i);
`endif
        end
    endtask

    // ---- Pack / replicate helpers (identical to tb_cim_top.v) ----------
    function [255:0] pack16;
        input [15:0] v0, v1, v2, v3, v4, v5, v6, v7;
        input [15:0] v8, v9, v10, v11, v12, v13, v14, v15;
        pack16 = {v15, v14, v13, v12, v11, v10, v9, v8,
                  v7,  v6,  v5,  v4,  v3,  v2,  v1, v0};
    endfunction
    function [255:0] pack32_8;
        input [7:0] v0 ,v1 ,v2 ,v3 ,v4 ,v5 ,v6 ,v7 ;
        input [7:0] v8 ,v9 ,v10,v11,v12,v13,v14,v15;
        input [7:0] v16,v17,v18,v19,v20,v21,v22,v23;
        input [7:0] v24,v25,v26,v27,v28,v29,v30,v31;
        pack32_8 = {v31,v30,v29,v28,v27,v26,v25,v24,
                    v23,v22,v21,v20,v19,v18,v17,v16,
                    v15,v14,v13,v12,v11,v10,v9 ,v8 ,
                    v7 ,v6 ,v5 ,v4 ,v3 ,v2 ,v1 ,v0 };
    endfunction
    function [255:0] rep16;
        input [15:0] v;
        rep16 = {16{v}};
    endfunction
    function [255:0] rep32_8;
        input [7:0] v;
        rep32_8 = {32{v}};
    endfunction

    // ---- Self-check helper ---------------------------------------------
    task automatic check;
        input [255:0]            tag;
        input [RES_WIDTH-1:0]    got;
        input [RES_WIDTH-1:0]    exp_val;
        input [RES_WIDTH-1:0]    tol;
        reg [RES_WIDTH-1:0] abs_diff;
        begin
            abs_diff = (got >= exp_val) ? (got - exp_val) : (exp_val - got);
            if (abs_diff <= tol) begin
                pass_cnt = pass_cnt + 1;
                $display("[TB] PASS %0s : got=%h exp=%h (|diff|=%0d, tol=%0d)",
                         tag, got, exp_val, abs_diff, tol);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[TB] FAIL %0s : got=%h exp=%h (|diff|=%0d, tol=%0d)",
                         tag, got, exp_val, abs_diff, tol);
            end
        end
    endtask

    // =====================================================================
    // posit -> real decoders (carried over from tb_cim_top.v)
    // =====================================================================
    function real p16_to_real;
        input [15:0] bits;
        reg          sign;
        reg [14:0]   mag;
        integer regime_run, regime_field_len, k, e_val;
        integer frac_pos, frac_width, i;
        real    frac_val, useed_pow;
        reg     done;
        begin
            if (bits[14:0] == 15'h0000) p16_to_real = 0.0;
            else begin
                sign = bits[15];
                if (sign) mag = (~bits[14:0]) + 15'd1;
                else      mag = bits[14:0];
                done       = 1'b0;
                regime_run = 1;
                for (i = 13; i >= 0; i = i - 1) begin
                    if (!done) begin
                        if (mag[i] == mag[14]) regime_run = regime_run + 1;
                        else                   done = 1'b1;
                    end
                end
                k                = mag[14] ? (regime_run - 1) : -regime_run;
                regime_field_len = done ? (regime_run + 1) : regime_run;
                e_val = 0;
                if (regime_field_len <= 13)
                    e_val = (mag[14 - regime_field_len] << 1)
                          |  mag[13 - regime_field_len];
                else if (regime_field_len == 14)
                    e_val = (mag[0] << 1);
                frac_pos   = 12 - regime_field_len;
                frac_width = (frac_pos >= 0) ? (frac_pos + 1) : 0;
                frac_val   = 0.0;
                for (i = 0; i < frac_width; i = i + 1)
                    if (mag[frac_pos - i])
                        frac_val = frac_val + 1.0 / (1 << (i + 1));
                useed_pow = 1.0;
                if (k >= 0)
                    for (i = 0; i < k;  i = i + 1) useed_pow = useed_pow * 16.0;
                else
                    for (i = 0; i < -k; i = i + 1) useed_pow = useed_pow / 16.0;
                p16_to_real = (sign ? -1.0 : 1.0)
                              * useed_pow * (1 << e_val) * (1.0 + frac_val);
            end
        end
    endfunction

    function real p8_to_real;
        input [7:0] bits;
        reg         sign;
        reg [6:0]   mag;
        integer regime_run, regime_field_len, k, e_val;
        integer frac_pos, frac_width, i;
        real    frac_val, useed_pow;
        reg     done;
        begin
            if (bits[6:0] == 7'h00) p8_to_real = 0.0;
            else begin
                sign = bits[7];
                if (sign) mag = (~bits[6:0]) + 7'd1;
                else      mag = bits[6:0];
                done       = 1'b0;
                regime_run = 1;
                for (i = 5; i >= 0; i = i - 1) begin
                    if (!done) begin
                        if (mag[i] == mag[6]) regime_run = regime_run + 1;
                        else                  done = 1'b1;
                    end
                end
                k                = mag[6] ? (regime_run - 1) : -regime_run;
                regime_field_len = done ? (regime_run + 1) : regime_run;
                e_val = 0;
                if (regime_field_len <= 5)
                    e_val = (mag[6 - regime_field_len] << 1)
                          |  mag[5 - regime_field_len];
                else if (regime_field_len == 6)
                    e_val = (mag[0] << 1);
                frac_pos   = 4 - regime_field_len;
                frac_width = (frac_pos >= 0) ? (frac_pos + 1) : 0;
                frac_val   = 0.0;
                for (i = 0; i < frac_width; i = i + 1)
                    if (mag[frac_pos - i])
                        frac_val = frac_val + 1.0 / (1 << (i + 1));
                useed_pow = 1.0;
                if (k >= 0)
                    for (i = 0; i < k;  i = i + 1) useed_pow = useed_pow * 16.0;
                else
                    for (i = 0; i < -k; i = i + 1) useed_pow = useed_pow / 16.0;
                p8_to_real = (sign ? -1.0 : 1.0)
                             * useed_pow * (1 << e_val) * (1.0 + frac_val);
            end
        end
    endfunction

    // =====================================================================
    // Posit constants (identical to tb_cim_top.v)
    // =====================================================================
    localparam [15:0] P16_ZERO   = 16'h0000;
    localparam [15:0] P16_NAR    = 16'h8000;
    localparam [15:0] P16_PONE   = 16'h4000;
    localparam [15:0] P16_NONE   = 16'hC000;
    localparam [15:0] P16_PTWO   = 16'h4800;
    localparam [15:0] P16_MAXPOS = 16'h7FFF;
    localparam [15:0] P16_MINPOS = 16'h0001;
    localparam [15:0] P16_4      = 16'h5000;
    localparam [15:0] P16_8      = 16'h5800;
    localparam [15:0] P16_16     = 16'h6000;
    localparam [15:0] P16_N16    = 16'hA000;
    localparam [15:0] P16_32     = 16'h6400;
    localparam [15:0] P16_64     = 16'h6800;
    localparam [15:0] P16_128    = 16'h6C00;
    localparam [15:0] P16_1024   = 16'h7400;
    localparam [15:0] P16_1P5    = 16'h4400;
    localparam [15:0] P16_36     = 16'h6480;
    localparam [15:0] P16_NXTMIN = 16'h0002;
    localparam [15:0] P16_24     = 16'h6200;
    localparam [15:0] P16_76     = 16'h68C0;
    localparam [15:0] P16_79     = 16'h68F0;
    localparam [15:0] P16_510    = 16'h71FC;
    localparam [7:0]  P8_ZERO    = 8'h00;
    localparam [7:0]  P8_PONE    = 8'h40;
    localparam [7:0]  P8_NONE    = 8'hC0;
    localparam [7:0]  P8_32      = 8'h64;
    localparam [7:0]  P8_N32     = 8'h9C;
    localparam [7:0]  P8_64      = 8'h68;

    // =====================================================================
    // Test driver
    // =====================================================================
    reg [RES_WIDTH-1:0] r_arr [0:15];   // per-core result scratchpad
    reg [RES_WIDTH-1:0] result_reg;
    integer             loop_i;
    integer             core_idx;
    integer             op_idx;
    reg [N_CIM-1:0]     mask;

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;

`ifdef VCD_PATH
        $dumpfile(`VCD_PATH);
`else
        $dumpfile("tb_cim_chip.vcd");
`endif
        $dumpvars(0, tb_cim_chip);

        do_reset;

        // =================================================================
        // Batch B1: T1..T16 distributed across cores 0..15 (parallel).
        // Each test contributes one MAC op.
        // =================================================================
        $display("[TB] === Batch B1: T1..T16 on 16 cores in parallel ===");

        // ---- Load SRAMs ---------------------------------------------------
        // T1 / core 0: 1 row of P16_PONE
        core_load_row(6'd0, 4'd0, rep16(P16_PONE), rep16(P16_PONE));
        // T2 / core 1: 2 rows of P16_PONE
        core_load_row(6'd1, 4'd0, rep16(P16_PONE), rep16(P16_PONE));
        core_load_row(6'd1, 4'd1, rep16(P16_PONE), rep16(P16_PONE));
        // T3 / core 2: specials mix
        core_load_row(6'd2, 4'd0,
            pack16(P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_NAR,  P16_NAR,  P16_NAR,  P16_NAR,
                   P16_ZERO, P16_ZERO, P16_ZERO, P16_ZERO,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE),
            rep16(P16_PONE));
        // T4 / core 3: +16 then -16 across 2 rows
        core_load_row(6'd3, 4'd0, rep16(P16_PONE), rep16(P16_PONE));
        core_load_row(6'd3, 4'd1, rep16(P16_NONE), rep16(P16_PONE));
        // T5 / core 4: P8 ones
        core_load_row(6'd4, 4'd0, rep32_8(P8_PONE), rep32_8(P8_PONE));
        // T6 / core 5: zero W
        core_load_row(6'd5, 4'd0, rep16(P16_ZERO), rep16(P16_PONE));
        // T7 / core 6: NaR W
        core_load_row(6'd6, 4'd0, rep16(P16_NAR), rep16(P16_PONE));
        // T8 / core 7: 8 rows of P16_PONE
        for (loop_i = 0; loop_i < 8; loop_i = loop_i + 1)
            core_load_row(6'd7, loop_i[3:0], rep16(P16_PONE), rep16(P16_PONE));
        // T9 / core 8: -1 W
        core_load_row(6'd8, 4'd0, rep16(P16_NONE), rep16(P16_PONE));
        // T10 / core 9: single-lane
        core_load_row(6'd9, 4'd0,
            pack16(P16_PONE, P16_ZERO, P16_ZERO, P16_ZERO,
                   P16_ZERO, P16_ZERO, P16_ZERO, P16_ZERO,
                   P16_ZERO, P16_ZERO, P16_ZERO, P16_ZERO,
                   P16_ZERO, P16_ZERO, P16_ZERO, P16_ZERO),
            rep16(P16_PONE));
        // T11 / core 10: mixed batch (2 rows)
        core_load_row(6'd10, 4'd0, rep16(P16_PONE), rep16(P16_PONE));
        core_load_row(6'd10, 4'd1,
            pack16(P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE),
            rep16(P16_PONE));
        // T12 / core 11: P8 -1 W
        core_load_row(6'd11, 4'd0, rep32_8(P8_NONE), rep32_8(P8_PONE));
        // T13 / core 12: P8 ones (2 rows)
        core_load_row(6'd12, 4'd0, rep32_8(P8_PONE), rep32_8(P8_PONE));
        core_load_row(6'd12, 4'd1, rep32_8(P8_PONE), rep32_8(P8_PONE));
        // T14 / core 13: same as T1
        core_load_row(6'd13, 4'd0, rep16(P16_PONE), rep16(P16_PONE));
        // T15 / core 14: 1.5*1.5
        core_load_row(6'd14, 4'd0, rep16(P16_1P5), rep16(P16_1P5));
        // T16 / core 15: maxpos
        core_load_row(6'd15, 4'd0, rep16(P16_MAXPOS), rep16(P16_PONE));

        // ---- Configure each core's job descriptor -------------------------
        core_cfg(6'd0,  POSIT16, 4'd0, 8'd1);   // T1
        core_cfg(6'd1,  POSIT16, 4'd0, 8'd2);   // T2
        core_cfg(6'd2,  POSIT16, 4'd0, 8'd1);   // T3
        core_cfg(6'd3,  POSIT16, 4'd0, 8'd2);   // T4
        core_cfg(6'd4,  POSIT8,  4'd0, 8'd2);   // T5
        core_cfg(6'd5,  POSIT16, 4'd0, 8'd1);   // T6
        core_cfg(6'd6,  POSIT16, 4'd0, 8'd1);   // T7
        core_cfg(6'd7,  POSIT16, 4'd0, 8'd8);   // T8
        core_cfg(6'd8,  POSIT16, 4'd0, 8'd1);   // T9
        core_cfg(6'd9,  POSIT16, 4'd0, 8'd1);   // T10
        core_cfg(6'd10, POSIT16, 4'd0, 8'd2);   // T11
        core_cfg(6'd11, POSIT8,  4'd0, 8'd2);   // T12
        core_cfg(6'd12, POSIT8,  4'd0, 8'd4);   // T13
        core_cfg(6'd13, POSIT16, 4'd0, 8'd1);   // T14
        core_cfg(6'd14, POSIT16, 4'd0, 8'd1);   // T15
        core_cfg(6'd15, POSIT16, 4'd0, 8'd1);   // T16

        // ---- Launch all 16 cores in one cycle, wait, harvest results ----
        mask = {N_CIM{1'b1}};
        launch_mask(mask);
        wait_mask_done(mask);

        for (core_idx = 0; core_idx < 16; core_idx = core_idx + 1)
            core_read_result(core_idx[5:0], r_arr[core_idx]);

        check("T1  P16 1.0*1.0 x16",   r_arr[0],       P16_16,     16'd2);
        check("T2  P16 acc 2x16.0",    r_arr[1],       P16_32,     16'd2);
        check("T3  P16 specials sum=0",r_arr[2],       P16_ZERO,   16'd2);
        check("T4  P16 +16 + -16 = 0", r_arr[3],       P16_ZERO,   16'd2);
        check("T5  P8  acc 32.0",      r_arr[4][15:8], P8_32,      8'd2);
        check("T6  P16 all-zero W",    r_arr[5],       P16_ZERO,   16'd2);
        check("T7  P16 all-NaR W",     r_arr[6],       P16_ZERO,   16'd2);
        check("T8  P16 acc 8x16=128",  r_arr[7],       P16_128,    16'd4);
        check("T9  P16 -16.0",         r_arr[8],       P16_N16,    16'd2);
        check("T10 P16 single lane=1", r_arr[9],       P16_PONE,   16'd2);
        check("T11 P16 mixed batch",   r_arr[10],      P16_16,     16'd2);
        check("T12 P8  acc -32.0",     r_arr[11][15:8],P8_N32,     8'd2);
        check("T13 P8  acc 4x16=64",   r_arr[12][15:8],P8_64,      8'd2);
        check("T14 P16 b2b repeat",    r_arr[13],      P16_16,     16'd2);
        check("T15 P16 1.5*1.5 x16=36",r_arr[14],      P16_36,     16'd2);
        check("T16 P16 maxpos sat",    r_arr[15],      P16_MAXPOS, 16'd0);

        clear_done(mask);

        // =================================================================
        // Batch B2: T17, T18, T19..T23 in parallel on cores 0..6.
        // =================================================================
        $display("[TB] === Batch B2: T17,T18,T19..T23 on 7 cores parallel ===");

        // T17 / core 0: minpos W (overwrites T1 SRAM contents)
        core_load_row(6'd0, 4'd0, rep16(P16_MINPOS), rep16(P16_PONE));

        // T18 / core 1: 16 rows of P16_PONE, batch=64 (relies on 4-bit addr wrap)
        for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1)
            core_load_row(6'd1, loop_i[3:0], rep16(P16_PONE), rep16(P16_PONE));

        // T19 / core 2: 8x1 + 8x2
        core_load_row(6'd2, 4'd0,
            pack16(P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PTWO, P16_PTWO, P16_PTWO, P16_PTWO,
                   P16_PTWO, P16_PTWO, P16_PTWO, P16_PTWO),
            rep16(P16_PONE));
        // T20 / core 3: 4x16 + 12x1
        core_load_row(6'd3, 4'd0,
            pack16(P16_16,   P16_16,   P16_16,   P16_16,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE),
            rep16(P16_PONE));
        // T21 / core 4: mixed sign+magnitude
        core_load_row(6'd4, 4'd0,
            pack16(P16_16,   P16_16,   P16_16,   P16_16,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE,
                   P16_PTWO, P16_PTWO, P16_PTWO, P16_PTWO,
                   P16_NONE, P16_NONE, P16_NONE, P16_NONE),
            rep16(P16_PONE));
        // T22 / core 5: 1x64 + 15x1
        core_load_row(6'd5, 4'd0,
            pack16(P16_64,   P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE,
                   P16_PONE, P16_PONE, P16_PONE, P16_PONE),
            rep16(P16_PONE));
        // T23 / core 6: all-different
        core_load_row(6'd6, 4'd0,
            pack16(P16_PONE, P16_PTWO, P16_4,    P16_8,
                   P16_16,   P16_32,   P16_64,   P16_128,
                   P16_PONE, P16_PTWO, P16_4,    P16_8,
                   P16_16,   P16_32,   P16_64,   P16_128),
            rep16(P16_PONE));

        core_cfg(6'd0, POSIT16, 4'd0, 8'd1);    // T17
        core_cfg(6'd1, POSIT16, 4'd0, 8'd64);   // T18
        core_cfg(6'd2, POSIT16, 4'd0, 8'd1);    // T19
        core_cfg(6'd3, POSIT16, 4'd0, 8'd1);    // T20
        core_cfg(6'd4, POSIT16, 4'd0, 8'd1);    // T21
        core_cfg(6'd5, POSIT16, 4'd0, 8'd1);    // T22
        core_cfg(6'd6, POSIT16, 4'd0, 8'd1);    // T23

        mask = 16'h007F;        // cores 0..6
        launch_mask(mask);
        wait_mask_done(mask);

        for (core_idx = 0; core_idx < 7; core_idx = core_idx + 1)
            core_read_result(core_idx[5:0], r_arr[core_idx]);

        check("T17 P16 minpos x16",       r_arr[0], P16_NXTMIN, 16'd1);
        check("T18 P16 acc 64x16=1024",   r_arr[1], P16_1024,   16'd2);
        check("T19 P16 8x1+8x2=24",       r_arr[2], P16_24,     16'd0);
        check("T20 P16 4x16+12x1=76",     r_arr[3], P16_76,     16'd0);
        check("T21 P16 mix sign+mag=64",  r_arr[4], P16_64,     16'd0);
        check("T22 P16 1x64+15x1=79",     r_arr[5], P16_79,     16'd0);
        check("T23 P16 all-different=510",r_arr[6], P16_510,    16'd0);

        clear_done(mask);

        // =================================================================
        // T24 (sequential on core 0): P16 -> P8 -> P16 on three SRAM rows.
        // Intent is per-mode state-cleanup on the SAME core, so sequential.
        // =================================================================
        $display("[TB] === T24: P16->P8->P16 sequential on core 0 ===");
        core_load_row(6'd0, 4'd0, rep16  (P16_PONE), rep16  (P16_PONE));
        core_load_row(6'd0, 4'd1, rep32_8(P8_PONE) , rep32_8(P8_PONE) );
        core_load_row(6'd0, 4'd2, rep16  (P16_PTWO), rep16  (P16_PONE));

        core_cfg(6'd0, POSIT16, 4'd0, 8'd1);
        launch_mask(16'h0001);  wait_mask_done(16'h0001);
        core_read_result(6'd0, result_reg);
        check("T24a P16 first  =16",  result_reg,        P16_16, 16'd0);
        clear_done(16'h0001);

        core_cfg(6'd0, POSIT8,  4'd1, 8'd2);
        launch_mask(16'h0001);  wait_mask_done(16'h0001);
        core_read_result(6'd0, result_reg);
        check("T24b P8  middle =32",  result_reg[15:8],  P8_32,  8'd0);
        clear_done(16'h0001);

        core_cfg(6'd0, POSIT16, 4'd2, 8'd1);
        launch_mask(16'h0001);  wait_mask_done(16'h0001);
        core_read_result(6'd0, result_reg);
        check("T24c P16 last   =32",  result_reg,        P16_32, 16'd0);
        clear_done(16'h0001);

        // =================================================================
        // T26 (sequential on core 0): 5x identical T1-style op.
        // Intent is per-op state-leak detection on the SAME core.
        // =================================================================
        $display("[TB] === T26: 5x repeat-isolation sequential on core 0 ===");
        core_load_row(6'd0, 4'd0, rep16(P16_PONE), rep16(P16_PONE));
        core_cfg(6'd0, POSIT16, 4'd0, 8'd1);
        for (loop_i = 0; loop_i < 5; loop_i = loop_i + 1) begin
            launch_mask(16'h0001);
            wait_mask_done(16'h0001);
            core_read_result(6'd0, result_reg);
            check("T26 P16 repeat-isolation", result_reg, P16_16, 16'd0);
            clear_done(16'h0001);
        end

        // =================================================================
        // T25 (standalone): assert global reset mid-flight on a 16-batch op
        // running on core 0, then run a fresh 1-batch op and verify.
        // =================================================================
        $display("[TB] === T25: mid-flight global reset (standalone) ===");
        for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1)
            core_load_row(6'd0, loop_i[3:0], rep16(P16_PONE), rep16(P16_PONE));
        core_cfg(6'd0, POSIT16, 4'd0, 8'd16);
        launch_mask(16'h0001);
        // Let it run for ~30 cycles, then yank the rug.
        repeat (30) @(posedge clk_333MHz_i);
        do_reset;
        // SRAM macros are not reset by rst_n, so the 16 rows survive.
        core_cfg(6'd0, POSIT16, 4'd0, 8'd1);
        launch_mask(16'h0001);  wait_mask_done(16'h0001);
        core_read_result(6'd0, result_reg);
        check("T25 P16 post-reset =16", result_reg, P16_16, 16'd0);
        clear_done(16'h0001);

        // =================================================================
        // MNIST regression with MSE comparison.
        //
        // Each regime fans 8 ops out to 8 cores: every core gets the SAME
        // 16-row W/A image (loaded once via $readmemh into local arrays),
        // but a distinct {batch_cnt, start_addr} from meta[op_i].  All 8
        // launch at once and run independently.
        // =================================================================
`ifdef MNIST_REAL_DATA
        // ----- Regime 1: posit16 layer 1 -------------------------------
        $display("[TB] === MNIST p16_l1: 8 ops parallel on cores 0..7 ===");
        $readmemh("testdata/p16_l1_w.hex",             mnist_p16_l1_w);
        $readmemh("testdata/p16_l1_a.hex",             mnist_p16_l1_a);
        $readmemh("testdata/p16_l1_expected.hex",      mnist_p16_l1_exp);
        $readmemh("testdata/p16_l1_expected_real.hex", mnist_p16_l1_real);
        $readmemh("testdata/p16_l1_meta.hex",          mnist_p16_l1_meta);

        for (core_idx = 0; core_idx < 8; core_idx = core_idx + 1) begin
            for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1) begin
                core_load_row(core_idx[5:0], loop_i[3:0],
                              mnist_p16_l1_w[loop_i],
                              mnist_p16_l1_a[loop_i]);
            end
            core_cfg(core_idx[5:0], POSIT16,
                     mnist_p16_l1_meta[core_idx][SRAM_ADDR_WIDTH-1:0],
                     mnist_p16_l1_meta[core_idx][23:16]);
        end
        mask = 16'h00FF;
        launch_mask(mask);  wait_mask_done(mask);

        mnist_sum_sq = 0.0;
        for (op_idx = 0; op_idx < 8; op_idx = op_idx + 1) begin
            core_read_result(op_idx[5:0], result_reg);
            mnist_got_real  = p16_to_real(result_reg);
            mnist_exp_real  = $bitstoreal(mnist_p16_l1_real[op_idx]);
            mnist_diff_real = mnist_got_real - mnist_exp_real;
            mnist_sum_sq    = mnist_sum_sq + mnist_diff_real * mnist_diff_real;
            $display("[TB] p16_l1 op %0d (core %0d) : got=%h(%g) exp(%g) diff=%g",
                     op_idx, op_idx, result_reg, mnist_got_real,
                     mnist_exp_real, mnist_diff_real);
        end
        mnist_mse = mnist_sum_sq / 8.0;
        if (mnist_mse <= 1.0e-6) begin
            pass_cnt = pass_cnt + 1;
            $display("[TB] PASS Tmnist p16_l1 MSE=%g (<=1e-6)", mnist_mse);
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("[TB] FAIL Tmnist p16_l1 MSE=%g (>1e-6)", mnist_mse);
        end
        clear_done(mask);

        // ----- Regime 2: posit16 layer 2 -------------------------------
        $display("[TB] === MNIST p16_l2: 8 ops parallel on cores 0..7 ===");
        $readmemh("testdata/p16_l2_w.hex",             mnist_p16_l2_w);
        $readmemh("testdata/p16_l2_a.hex",             mnist_p16_l2_a);
        $readmemh("testdata/p16_l2_expected.hex",      mnist_p16_l2_exp);
        $readmemh("testdata/p16_l2_expected_real.hex", mnist_p16_l2_real);
        $readmemh("testdata/p16_l2_meta.hex",          mnist_p16_l2_meta);

        for (core_idx = 0; core_idx < 8; core_idx = core_idx + 1) begin
            for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1) begin
                core_load_row(core_idx[5:0], loop_i[3:0],
                              mnist_p16_l2_w[loop_i],
                              mnist_p16_l2_a[loop_i]);
            end
            core_cfg(core_idx[5:0], POSIT16,
                     mnist_p16_l2_meta[core_idx][SRAM_ADDR_WIDTH-1:0],
                     mnist_p16_l2_meta[core_idx][23:16]);
        end
        mask = 16'h00FF;
        launch_mask(mask);  wait_mask_done(mask);

        mnist_sum_sq = 0.0;
        for (op_idx = 0; op_idx < 8; op_idx = op_idx + 1) begin
            core_read_result(op_idx[5:0], result_reg);
            mnist_got_real  = p16_to_real(result_reg);
            mnist_exp_real  = $bitstoreal(mnist_p16_l2_real[op_idx]);
            mnist_diff_real = mnist_got_real - mnist_exp_real;
            mnist_sum_sq    = mnist_sum_sq + mnist_diff_real * mnist_diff_real;
            $display("[TB] p16_l2 op %0d (core %0d) : got=%h(%g) exp(%g) diff=%g",
                     op_idx, op_idx, result_reg, mnist_got_real,
                     mnist_exp_real, mnist_diff_real);
        end
        mnist_mse = mnist_sum_sq / 8.0;
        if (mnist_mse <= 1.0e-6) begin
            pass_cnt = pass_cnt + 1;
            $display("[TB] PASS Tmnist p16_l2 MSE=%g (<=1e-6)", mnist_mse);
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("[TB] FAIL Tmnist p16_l2 MSE=%g (>1e-6)", mnist_mse);
        end
        clear_done(mask);

        // ----- Regime 3: posit8 layer 1 --------------------------------
        $display("[TB] === MNIST p8_l1: 8 ops parallel on cores 0..7 ===");
        $readmemh("testdata/p8_l1_w.hex",             mnist_p8_l1_w);
        $readmemh("testdata/p8_l1_a.hex",             mnist_p8_l1_a);
        $readmemh("testdata/p8_l1_expected.hex",      mnist_p8_l1_exp);
        $readmemh("testdata/p8_l1_expected_real.hex", mnist_p8_l1_real);
        $readmemh("testdata/p8_l1_meta.hex",          mnist_p8_l1_meta);

        for (core_idx = 0; core_idx < 8; core_idx = core_idx + 1) begin
            for (loop_i = 0; loop_i < 16; loop_i = loop_i + 1) begin
                core_load_row(core_idx[5:0], loop_i[3:0],
                              mnist_p8_l1_w[loop_i],
                              mnist_p8_l1_a[loop_i]);
            end
            core_cfg(core_idx[5:0], POSIT8,
                     mnist_p8_l1_meta[core_idx][SRAM_ADDR_WIDTH-1:0],
                     mnist_p8_l1_meta[core_idx][23:16]);
        end
        mask = 16'h00FF;
        launch_mask(mask);  wait_mask_done(mask);

        mnist_sum_sq = 0.0;
        for (op_idx = 0; op_idx < 8; op_idx = op_idx + 1) begin
            core_read_result(op_idx[5:0], result_reg);
            // Posit8 result lands in result_reg[15:8] per cim_top spec.
            mnist_got_real  = p8_to_real(result_reg[15:8]);
            mnist_exp_real  = $bitstoreal(mnist_p8_l1_real[op_idx]);
            mnist_diff_real = mnist_got_real - mnist_exp_real;
            mnist_sum_sq    = mnist_sum_sq + mnist_diff_real * mnist_diff_real;
            $display("[TB] p8_l1  op %0d (core %0d) : got=%h(%g) exp(%g) diff=%g",
                     op_idx, op_idx, result_reg[15:8], mnist_got_real,
                     mnist_exp_real, mnist_diff_real);
        end
        mnist_mse = mnist_sum_sq / 8.0;
        if (mnist_mse <= 1.0e-2) begin
            pass_cnt = pass_cnt + 1;
            $display("[TB] PASS Tmnist p8_l1  MSE=%g (<=1e-2)", mnist_mse);
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("[TB] FAIL Tmnist p8_l1  MSE=%g (>1e-2)", mnist_mse);
        end
        clear_done(mask);
`endif

        // =================================================================
        // Summary
        // =================================================================
        $display("[TB] ===========================================");
        $display("[TB] Total: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("[TB] ===========================================");
        if (fail_cnt == 0) begin
            $display("[TB] OVERALL: PASS");
        end
        else begin
            $display("[TB] OVERALL: FAIL");
`ifdef TB_FATAL_ON_FAIL
            $fatal(1, "[TB] chip-level regression failed with %0d failures", fail_cnt);
`endif
        end
        $finish;
    end

    // ---- Watchdog --------------------------------------------------------
    initial begin
        #(2000000);
        $display("[TB] FATAL: simulation watchdog expired");
        $finish;
    end

endmodule
