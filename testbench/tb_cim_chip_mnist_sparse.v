`timescale 1ns/1ps
// =============================================================================
// Module : tb_cim_chip_mnist_sparse
// Purpose: Chip-level MNIST-based sparsity/energy testbench.
//
// This TB is intentionally separate from the original functional tb_cim_chip.v.
// It does NOT run T1-T26.  It only runs one selected MNIST regime across a
// selected core mask, applies random zero masks on top of the real MNIST hex
// data, records cycles/ops, and optionally dumps only the compute window.
//
// Intended use:
//   cim_chip post-route GLS -> VCD -> SAIF -> PrimePower.
// =============================================================================

`ifndef CLK_PERIOD
  `define CLK_PERIOD 3.0
`endif
`define HALF_PERIOD (`CLK_PERIOD/2.0)

`ifndef DUT_NAME
  `define DUT_NAME "cim_chip"
`endif

`ifndef VCD_PATH
  `define VCD_PATH "tb_cim_chip_mnist_sparse.vcd"
`endif

`ifndef PERF_CSV_PATH
  `define PERF_CSV_PATH "tb_cim_chip_mnist_sparse_perf.csv"
`endif

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

module tb_cim_chip_mnist_sparse;

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

    localparam [15:0] P16_ZERO = 16'h0000;
    localparam [15:0] P16_NAR  = 16'h8000;
    localparam [7:0]  P8_ZERO  = 8'h00;
    localparam [7:0]  P8_NAR   = 8'h80;

    // DUT I/O
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

    // Cycle counter
    reg [31:0] cycle_cnt;
    always @(posedge clk_333MHz_i or negedge rst_n_i) begin
        if (!rst_n_i) cycle_cnt <= 32'd0;
        else          cycle_cnt <= cycle_cnt + 32'd1;
    end

    // MNIST data
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l1_w    [0:15];
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l1_a    [0:15];
    reg [23:0]                mnist_p16_l1_meta [0:7];

    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l2_w    [0:15];
    reg [SRAM_DATA_WIDTH-1:0] mnist_p16_l2_a    [0:15];
    reg [23:0]                mnist_p16_l2_meta [0:7];

    reg [SRAM_DATA_WIDTH-1:0] mnist_p8_l1_w     [0:15];
    reg [SRAM_DATA_WIDTH-1:0] mnist_p8_l1_a     [0:15];
    reg [23:0]                mnist_p8_l1_meta  [0:7];

    // Per-core masked rows
    reg [SRAM_DATA_WIDTH-1:0] masked_w [0:N_CIM-1][0:15];
    reg [SRAM_DATA_WIDTH-1:0] masked_a [0:N_CIM-1][0:15];

    // Runtime config
    reg [1023:0] workload_arg;
    integer a_sparsity_pct;
    integer w_sparsity_pct;
    integer mask_seed_base;
    integer max_ops;
    integer active_cores;
    reg [N_CIM-1:0] core_mask;
    integer perf_csv;
    integer pass_cnt;
    integer fail_cnt;

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
        $display("[TB] WARNING: POST_SYN is set but SDF_PATH is not provided.");
`endif
    end
`endif

    initial begin
        clk_333MHz_i = 1'b0;
        forever #(`HALF_PERIOD) clk_333MHz_i = ~clk_333MHz_i;
    end

    // Address map follows the existing tb_cim_chip.v host interface.
    function [HOST_ADDR_WIDTH-1:0] addr_shadow_w;
        input [5:0] core_id;
        begin
            addr_shadow_w = {4'h0, core_id, 6'h00};
        end
    endfunction

    function [HOST_ADDR_WIDTH-1:0] addr_commit_a;
        input [5:0] core_id;
        input [3:0] row;
        begin
            addr_commit_a = {4'h1, core_id, 2'b00, row};
        end
    endfunction

    function [HOST_ADDR_WIDTH-1:0] addr_cfg;
        input [5:0] core_id;
        begin
            addr_cfg = {4'h2, core_id, 6'h00};
        end
    endfunction

    function [HOST_ADDR_WIDTH-1:0] addr_result;
        input [5:0] core_id;
        begin
            addr_result = {4'h3, core_id, 6'h00};
        end
    endfunction

    localparam [HOST_ADDR_WIDTH-1:0] ADDR_LAUNCH   = {4'h8, 12'h000};
    localparam [HOST_ADDR_WIDTH-1:0] ADDR_GBL_STAT = {4'h9, 12'h000};
    localparam [HOST_ADDR_WIDTH-1:0] ADDR_CLEAR_DN = {4'hA, 12'h000};

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
        input [5:0] core_id;
        input [3:0] row;
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
            bus_write(ADDR_LAUNCH, {{(HOST_DATA_WIDTH-N_CIM){1'b0}}, mask});
        end
    endtask

    task automatic clear_done;
        input [N_CIM-1:0] mask;
        begin
            bus_write(ADDR_CLEAR_DN, {{(HOST_DATA_WIDTH-N_CIM){1'b0}}, mask});
        end
    endtask

    task automatic wait_mask_done_perf;
        input [N_CIM-1:0] mask;
        output [31:0] total_cycles;
        output [31:0] busy_cycles;
        output integer ok;
        integer timeout;
        integer bc;
        reg [HOST_DATA_WIDTH-1:0] rd;
        reg [N_CIM-1:0] done_latch;
        reg [31:0] t_start;
        reg [31:0] t_end;
        begin
            ok = 1;
            timeout = 0;
            bc = 0;
            done_latch = {N_CIM{1'b0}};

`ifdef ENERGY_COMPUTE_DUMP
            $dumpon;
`endif

            launch_mask(mask);
            t_start = cycle_cnt;

            while (((done_latch & mask) != mask) && (timeout < 200000)) begin
                bus_read(ADDR_GBL_STAT, rd);
                done_latch = rd[N_CIM +: N_CIM];
                if (busy_any_o) bc = bc + 1;
                timeout = timeout + 1;
            end

            t_end = cycle_cnt;
            total_cycles = t_end - t_start;
            busy_cycles = bc[31:0];

            if ((done_latch & mask) != mask) begin
                $display("[TB] TIMEOUT waiting for done mask=%h got=%h", mask, done_latch);
                ok = 0;
            end

`ifdef ENERGY_COMPUTE_DUMP
            $dumpoff;
`endif
            clear_done(mask);
        end
    endtask

    task automatic core_read_result;
        input [5:0] core_id;
        output [15:0] result;
        reg [HOST_DATA_WIDTH-1:0] rd;
        begin
            bus_read(addr_result(core_id), rd);
            result = rd[15:0];
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

    function automatic integer rand_pct;
        inout integer seed;
        integer r;
        begin
            r = $random(seed);
            if (r < 0) r = -r;
            rand_pct = r % 100;
        end
    endfunction

    task automatic mask_p16_row;
        input  [255:0] row_in;
        input  integer pct;
        inout  integer seed;
        output [255:0] row_out;
        integer lane;
        reg [15:0] v;
        begin
            row_out = 256'd0;
            for (lane = 0; lane < 16; lane = lane + 1) begin
                v = row_in[16*lane +: 16];
                if (rand_pct(seed) < pct)
                    row_out[16*lane +: 16] = P16_ZERO;
                else
                    row_out[16*lane +: 16] = v;
            end
        end
    endtask

    task automatic mask_p8_row;
        input  [255:0] row_in;
        input  integer pct;
        inout  integer seed;
        output [255:0] row_out;
        integer lane;
        reg [7:0] v;
        begin
            row_out = 256'd0;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                v = row_in[8*lane +: 8];
                if (rand_pct(seed) < pct)
                    row_out[8*lane +: 8] = P8_ZERO;
                else
                    row_out[8*lane +: 8] = v;
            end
        end
    endtask

    function automatic integer p16_pair_nonzero;
        input [15:0] wv;
        input [15:0] av;
        begin
            p16_pair_nonzero = ((wv != P16_ZERO) && (wv != P16_NAR) &&
                                (av != P16_ZERO) && (av != P16_NAR));
        end
    endfunction

    function automatic integer p8_pair_nonzero;
        input [7:0] wv;
        input [7:0] av;
        begin
            p8_pair_nonzero = ((wv != P8_ZERO) && (wv != P8_NAR) &&
                               (av != P8_ZERO) && (av != P8_NAR));
        end
    endfunction

    task automatic count_core_p16_window;
        input integer core;
        input integer start_addr;
        input integer bcnt;
        output integer dense_macs;
        output integer effective_macs;
        integer bi;
        integer lane;
        integer row;
        reg [15:0] wv;
        reg [15:0] av;
        begin
            dense_macs = 0;
            effective_macs = 0;
            for (bi = 0; bi < bcnt; bi = bi + 1) begin
                row = (start_addr + bi) & 4'hF;
                dense_macs = dense_macs + 16;
                for (lane = 0; lane < 16; lane = lane + 1) begin
                    wv = masked_w[core][row][16*lane +: 16];
                    av = masked_a[core][row][16*lane +: 16];
                    if (p16_pair_nonzero(wv, av))
                        effective_macs = effective_macs + 1;
                end
            end
        end
    endtask

    task automatic count_core_p8_window;
        input integer core;
        input integer start_addr;
        input integer bcnt;
        output integer dense_macs;
        output integer effective_macs;
        integer bi;
        integer lane;
        integer row;
        integer half;
        integer phys_lane;
        reg [7:0] wv;
        reg [7:0] av;
        begin
            dense_macs = 0;
            effective_macs = 0;
            for (bi = 0; bi < bcnt; bi = bi + 1) begin
                row = (start_addr + (bi >> 1)) & 4'hF;
                half = bi & 1;
                dense_macs = dense_macs + 16;
                for (lane = 0; lane < 16; lane = lane + 1) begin
                    phys_lane = half*16 + lane;
                    wv = masked_w[core][row][8*phys_lane +: 8];
                    av = masked_a[core][row][8*phys_lane +: 8];
                    if (p8_pair_nonzero(wv, av))
                        effective_macs = effective_macs + 1;
                end
            end
        end
    endtask

    function automatic integer has_x16;
        input [15:0] v;
        begin
            has_x16 = (^v === 1'bx);
        end
    endfunction

    task automatic load_mnist_hex;
        begin
            $readmemh("testdata/p16_l1_w.hex",    mnist_p16_l1_w);
            $readmemh("testdata/p16_l1_a.hex",    mnist_p16_l1_a);
            $readmemh("testdata/p16_l1_meta.hex", mnist_p16_l1_meta);

            $readmemh("testdata/p16_l2_w.hex",    mnist_p16_l2_w);
            $readmemh("testdata/p16_l2_a.hex",    mnist_p16_l2_a);
            $readmemh("testdata/p16_l2_meta.hex", mnist_p16_l2_meta);

            $readmemh("testdata/p8_l1_w.hex",     mnist_p8_l1_w);
            $readmemh("testdata/p8_l1_a.hex",     mnist_p8_l1_a);
            $readmemh("testdata/p8_l1_meta.hex",  mnist_p8_l1_meta);
        end
    endtask

    task automatic prepare_core_rows;
        input integer core;
        input integer is_p8;
        integer i;
        integer seed_w;
        integer seed_a;
        begin
            seed_w = (mask_seed_base + core*1009) ^ 32'h13572468;
            seed_a = (mask_seed_base + core*1009) ^ 32'h24681357;

            for (i = 0; i < 16; i = i + 1) begin
                if (is_p8) begin
                    mask_p8_row(mnist_p8_l1_w[i], w_sparsity_pct, seed_w, masked_w[core][i]);
                    mask_p8_row(mnist_p8_l1_a[i], a_sparsity_pct, seed_a, masked_a[core][i]);
                end
                else if (workload_arg == "p16_l2") begin
                    mask_p16_row(mnist_p16_l2_w[i], w_sparsity_pct, seed_w, masked_w[core][i]);
                    mask_p16_row(mnist_p16_l2_a[i], a_sparsity_pct, seed_a, masked_a[core][i]);
                end
                else begin
                    mask_p16_row(mnist_p16_l1_w[i], w_sparsity_pct, seed_w, masked_w[core][i]);
                    mask_p16_row(mnist_p16_l1_a[i], a_sparsity_pct, seed_a, masked_a[core][i]);
                end

                core_load_row(core[5:0], i[3:0], masked_w[core][i], masked_a[core][i]);
            end
        end
    endtask

    task automatic get_meta;
        input integer op_idx;
        input integer is_p8;
        output integer bcnt;
        output integer addr;
        reg [23:0] m;
        begin
            if (is_p8)
                m = mnist_p8_l1_meta[op_idx];
            else if (workload_arg == "p16_l2")
                m = mnist_p16_l2_meta[op_idx];
            else
                m = mnist_p16_l1_meta[op_idx];

            bcnt = m[23:16];
            addr = m[3:0];
        end
    endtask

    task automatic build_core_mask;
        integer c;
        integer parsed_mask;
        begin
            if ($value$plusargs("CORE_MASK_HEX=%h", parsed_mask)) begin
                core_mask = parsed_mask[N_CIM-1:0];
            end
            else begin
                core_mask = {N_CIM{1'b0}};
                for (c = 0; c < active_cores && c < N_CIM; c = c + 1)
                    core_mask[c] = 1'b1;
            end
        end
    endtask

    task automatic run_selected_workload;
        integer is_p8;
        integer mode_bit;
        integer op;
        integer n_ops;
        integer bcnt;
        integer addr;
        integer core;
        integer dense_core;
        integer eff_core;
        integer dense_total;
        integer eff_total;
        integer dense_ops;
        integer effective_ops;
        integer ok;
        integer result_ok;
        reg [31:0] cycles;
        reg [31:0] busy_cycles;
        reg [15:0] r;
        begin
            is_p8 = (workload_arg == "p8_l1");
            mode_bit = is_p8 ? POSIT8 : POSIT16;

            load_mnist_hex();
            build_core_mask();

            for (core = 0; core < N_CIM; core = core + 1) begin
                if (core_mask[core])
                    prepare_core_rows(core, is_p8);
            end

            n_ops = max_ops;
            if (n_ops > 8) n_ops = 8;
            if (n_ops < 1) n_ops = 1;

            $display("[WORKLOAD] dut=%0s workload=%0s a_sp=%0d w_sp=%0d seed=%0d active_cores=%0d core_mask=%h max_ops=%0d",
                     `DUT_NAME, workload_arg, a_sparsity_pct, w_sparsity_pct,
                     mask_seed_base, active_cores, core_mask, n_ops);

            for (op = 0; op < n_ops; op = op + 1) begin
                get_meta(op, is_p8, bcnt, addr);

                dense_total = 0;
                eff_total = 0;

                for (core = 0; core < N_CIM; core = core + 1) begin
                    if (core_mask[core]) begin
                        if (is_p8)
                            count_core_p8_window(core, addr, bcnt, dense_core, eff_core);
                        else
                            count_core_p16_window(core, addr, bcnt, dense_core, eff_core);

                        dense_total = dense_total + dense_core;
                        eff_total = eff_total + eff_core;

                        core_cfg(core[5:0], mode_bit[0], addr[3:0], bcnt[7:0]);
                    end
                end

                wait_mask_done_perf(core_mask, cycles, busy_cycles, ok);

                result_ok = ok;
                for (core = 0; core < N_CIM; core = core + 1) begin
                    if (core_mask[core]) begin
                        core_read_result(core[5:0], r);
                        if (has_x16(r)) begin
                            $display("[TB] FAIL core=%0d result has X: %h", core, r);
                            result_ok = 0;
                        end
                    end
                end

                dense_ops = dense_total * 2;
                effective_ops = eff_total * 2;

                if (result_ok) pass_cnt = pass_cnt + 1;
                else           fail_cnt = fail_cnt + 1;

                $display("[PERF] dut=%0s workload=%0s op=%0d mode=%0s active_cores=%0d core_mask=%h batch_cnt=%0d start_addr=%0d cycles=%0d busy_cycles=%0d dense_macs=%0d effective_macs=%0d dense_ops=%0d effective_ops=%0d status=%0s",
                         `DUT_NAME, workload_arg, op, is_p8 ? "P8" : "P16",
                         active_cores, core_mask, bcnt, addr,
                         cycles, busy_cycles, dense_total, eff_total,
                         dense_ops, effective_ops,
                         result_ok ? "PASS" : "FAIL");

                if (perf_csv != 0) begin
                    $fwrite(perf_csv,
                            "%0s,%0s,%0s,%0d,%0d,%0d,%0d,%h,%0d,%0s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0s\n",
                            `DUT_NAME, `DUT_NAME, workload_arg,
                            a_sparsity_pct, w_sparsity_pct, mask_seed_base,
                            op, core_mask, active_cores,
                            is_p8 ? "P8" : "P16", bcnt, addr,
                            cycles, busy_cycles,
                            dense_total, eff_total,
                            dense_ops, effective_ops,
                            result_ok ? "PASS" : "FAIL");
                end
            end
        end
    endtask

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;

        if (!$value$plusargs("WORKLOAD=%s", workload_arg))
            workload_arg = "p16_l1";
        if (!$value$plusargs("A_SPARSITY_PCT=%d", a_sparsity_pct))
            a_sparsity_pct = 0;
        if (!$value$plusargs("W_SPARSITY_PCT=%d", w_sparsity_pct))
            w_sparsity_pct = 0;
        if (!$value$plusargs("MASK_SEED=%d", mask_seed_base))
            mask_seed_base = 1;
        if (!$value$plusargs("MAX_OPS=%d", max_ops))
            max_ops = 8;
        if (!$value$plusargs("ACTIVE_CORES=%d", active_cores))
            active_cores = 16;

        $dumpfile(`VCD_PATH);
        $dumpvars(0, tb_cim_chip_mnist_sparse);
`ifdef ENERGY_COMPUTE_DUMP
        $dumpoff;
`endif

        perf_csv = $fopen(`PERF_CSV_PATH, "w");
        if (perf_csv != 0) begin
            $fwrite(perf_csv,
                    "design_key,dut,workload,a_sparsity_pct,w_sparsity_pct,seed,op_idx,core_mask,active_cores,mode,batch_cnt,start_addr,cycles,busy_cycles,dense_macs,effective_macs,dense_ops,effective_ops,status\n");
        end

        do_reset;
        run_selected_workload();

        if (perf_csv != 0) $fclose(perf_csv);

        $display("[RESULT] dut=%0s workload=%0s pass=%0d fail=%0d",
                 `DUT_NAME, workload_arg, pass_cnt, fail_cnt);

        if (fail_cnt == 0) begin
            $display("[TB] OVERALL PASS");
        end else begin
            $display("[TB] OVERALL FAIL fail_cnt=%0d", fail_cnt);
        end

`ifdef TB_FATAL_ON_FAIL
        if (fail_cnt != 0) $fatal;
`endif
        $finish;
    end

    initial begin
        #(10000000);
        $display("[TB] FATAL: simulation watchdog expired");
        $finish;
    end

endmodule
