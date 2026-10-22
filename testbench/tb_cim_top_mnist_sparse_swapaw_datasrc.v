`timescale 1ns/1ps
// =============================================================================
// Module : tb_cim_top_mnist_sparse
// Purpose: Single-core MNIST-based sparsity/energy testbench.
//
// This TB is intentionally separate from the original functional tb_cim_top.v.
// It does NOT run T1-T26.  It only runs one selected MNIST regime, applies
// random zero masks on top of the real MNIST hex data, records cycles/ops, and
// optionally dumps only the compute window for SAIF/PrimePower.
//
// Intended use:
//   - top_hier / abl_mf / abl_mult / abl_dec post-route GLS
//   - VCD -> SAIF -> PrimePower
//
// Key idea:
//   read real MNIST W/A hex -> randomly replace selected operands by posit zero
//   -> keep all unmasked nonzero values exactly as in the original MNIST hex.
// =============================================================================

`ifndef HALF_PERIOD
  `ifdef CLK_PERIOD
    `define HALF_PERIOD (`CLK_PERIOD/2.0)
  `else
    `define HALF_PERIOD 1.4
  `endif
`endif

`ifndef DUT_TOP
  `define DUT_TOP cim_top
`endif

`ifndef DUT_NAME
  `define DUT_NAME "cim_top"
`endif

`ifndef VCD_PATH
  `define VCD_PATH "tb_cim_top_mnist_sparse.vcd"
`endif

`ifndef PERF_CSV_PATH
  `define PERF_CSV_PATH "tb_cim_top_mnist_sparse_perf.csv"
`endif

// -----------------------------------------------------------------------------
// Behavioural posit_cim_storage_wrapper for RTL-only simulation.
// In gate-level/post-route GLS, compile with +define+HAVE_REAL_RF_WRAPPER.
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

module tb_cim_top_mnist_sparse;

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

    localparam [15:0] P16_ZERO = 16'h0000;
    localparam [15:0] P16_NAR  = 16'h8000;
    localparam [7:0]  P8_ZERO  = 8'h00;
    localparam [7:0]  P8_NAR   = 8'h80;

    // DUT I/O
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

    // Masked rows actually loaded into SRAM
    reg [SRAM_DATA_WIDTH-1:0] masked_w [0:15];
    reg [SRAM_DATA_WIDTH-1:0] masked_a [0:15];

    // Runtime configuration
    reg [1023:0] workload_arg;
    integer a_sparsity_pct;
    integer w_sparsity_pct;
    integer mask_seed_base;
    integer max_ops;
    integer data_source_mode; // 0=MNIST, 1=synthetic dense, 2=hybrid MNIST@0 else synthetic dense
    integer perf_csv;
    integer fail_cnt;
    integer pass_cnt;

    // DUT instance
`ifndef POST_SYN
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
            repeat (20) @(posedge clk_333MHz_i);
`endif
        end
    endtask

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

    function automatic [15:0] rand_p16_nonzero;
        inout integer seed;
        reg [15:0] v;
        begin
            v = $random(seed);
            // Avoid POSIT zero and NaR so DATA_SOURCE_MODE=1 is truly dense.
            if ((v == P16_ZERO) || (v == P16_NAR))
                v = 16'h4000;
            rand_p16_nonzero = v;
        end
    endfunction

    function automatic [7:0] rand_p8_nonzero;
        inout integer seed;
        reg [7:0] v;
        begin
            v = $random(seed);
            // Avoid POSIT zero and NaR so DATA_SOURCE_MODE=1 is truly dense.
            if ((v == P8_ZERO) || (v == P8_NAR))
                v = 8'h40;
            rand_p8_nonzero = v;
        end
    endfunction

    task automatic gen_dense_p16_row;
        inout integer seed;
        output [255:0] row_out;
        integer lane;
        begin
            row_out = 256'd0;
            for (lane = 0; lane < 16; lane = lane + 1) begin
                row_out[16*lane +: 16] = rand_p16_nonzero(seed);
            end
        end
    endtask

    task automatic gen_dense_p8_row;
        inout integer seed;
        output [255:0] row_out;
        integer lane;
        begin
            row_out = 256'd0;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                row_out[8*lane +: 8] = rand_p8_nonzero(seed);
            end
        end
    endtask

    function automatic integer use_synth_dense_rows;
        begin
            // 0: MNIST for all sparsity points.
            // 1: synthetic dense for all sparsity points.
            // 2: hybrid, A=0/W=0 uses MNIST, otherwise synthetic dense.
            if (data_source_mode == 1)
                use_synth_dense_rows = 1;
            else if ((data_source_mode == 2) && ((a_sparsity_pct > 0) || (w_sparsity_pct > 0)))
                use_synth_dense_rows = 1;
            else
                use_synth_dense_rows = 0;
        end
    endfunction

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

    task automatic count_p16_window;
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
                    wv = masked_w[row][16*lane +: 16];
                    av = masked_a[row][16*lane +: 16];
                    if (p16_pair_nonzero(wv, av))
                        effective_macs = effective_macs + 1;
                end
            end
        end
    endtask

    // P8 mode: one 256-bit physical row has 32 P8 lanes, consumed as two
    // 16-lane batches. batch index 0 -> lanes 0..15, batch index 1 -> 16..31.
    task automatic count_p8_window;
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
                row  = (start_addr + (bi >> 1)) & 4'hF;
                half = bi & 1;
                dense_macs = dense_macs + 16;
                for (lane = 0; lane < 16; lane = lane + 1) begin
                    phys_lane = half*16 + lane;
                    wv = masked_w[row][8*phys_lane +: 8];
                    av = masked_a[row][8*phys_lane +: 8];
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

    task automatic run_mac_perf;
        input                       mode;
        input [BATCH_WIDTH-1:0]     bcnt;
        input [SRAM_ADDR_WIDTH-1:0] addr;
        output [RES_WIDTH-1:0]      result;
        output [31:0]               total_cycles;
        output [31:0]               busy_cycles;
        output integer              ok;
        integer timeout;
        integer bc;
        reg [31:0] t_start;
        reg [31:0] t_end;
        begin
            ok = 1;
            @(negedge clk_333MHz_i);
            if (busy_o !== 1'b0) begin
                $display("[TB] FAIL busy_o asserted before start");
                ok = 0;
            end

            data_mode_i  = mode;
            batch_cnt_i  = bcnt;
            start_addr_i = addr;

`ifdef ENERGY_COMPUTE_DUMP
            $dumpon;
`endif

            start_i = 1'b1;
            t_start = cycle_cnt;
            @(negedge clk_333MHz_i);
            start_i = 1'b0;

            timeout = 0;
            bc = 0;
            while (!done_o && (timeout < 100000)) begin
                @(posedge clk_333MHz_i);
                if (busy_o) bc = bc + 1;
                timeout = timeout + 1;
            end

            t_end = cycle_cnt;
            total_cycles = t_end - t_start;
            busy_cycles  = bc[31:0];

            if (!done_o) begin
                $display("[TB] ERROR: timeout waiting for done_o");
                result = 16'hxxxx;
                ok = 0;
            end else begin
                result = posit_o;
            end

            if (bc == 0) begin
                $display("[TB] FAIL busy_o never asserted");
                ok = 0;
            end

            @(negedge clk_333MHz_i);
            @(negedge clk_333MHz_i);
            if (busy_o !== 1'b0) begin
                $display("[TB] FAIL busy_o still asserted after done");
                ok = 0;
            end

            if (has_x16(result)) begin
                $display("[TB] FAIL result has X: %h", result);
                ok = 0;
            end

`ifdef ENERGY_COMPUTE_DUMP
            $dumpoff;
`endif
        end
    endtask

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

    task automatic prepare_masked_rows;
        input integer is_p8;
        integer i;
        integer seed_w;
        integer seed_a;
        integer seed_dense_w;
        integer seed_dense_a;
        reg [255:0] raw_w;
        reg [255:0] raw_a;
        integer synth_en;
        begin
            seed_w       = mask_seed_base ^ 32'h13572468;
            seed_a       = mask_seed_base ^ 32'h24681357;
            seed_dense_w = mask_seed_base ^ 32'h55aa1234;
            seed_dense_a = mask_seed_base ^ 32'haa55abcd;
            synth_en     = use_synth_dense_rows();

            $display("[DATA_SOURCE] mode=%0d synth_dense=%0d (0=MNIST,1=SYNTH_DENSE,2=HYBRID)",
                     data_source_mode, synth_en);

            for (i = 0; i < 16; i = i + 1) begin
                if (synth_en) begin
                    if (is_p8) begin
                        gen_dense_p8_row(seed_dense_w, raw_w);
                        gen_dense_p8_row(seed_dense_a, raw_a);
                    end else begin
                        gen_dense_p16_row(seed_dense_w, raw_w);
                        gen_dense_p16_row(seed_dense_a, raw_a);
                    end
                end else begin
                    if (is_p8) begin
                        raw_w = mnist_p8_l1_w[i];
                        raw_a = mnist_p8_l1_a[i];
                    end
                    else if (workload_arg == "p16_l2") begin
                        raw_w = mnist_p16_l2_w[i];
                        raw_a = mnist_p16_l2_a[i];
                    end
                    else begin
                        raw_w = mnist_p16_l1_w[i];
                        raw_a = mnist_p16_l1_a[i];
                    end
                end

                if (is_p8) begin
                    mask_p8_row(raw_w, w_sparsity_pct, seed_w, masked_w[i]);
                    mask_p8_row(raw_a, a_sparsity_pct, seed_a, masked_a[i]);
                end else begin
                    mask_p16_row(raw_w, w_sparsity_pct, seed_w, masked_w[i]);
                    mask_p16_row(raw_a, a_sparsity_pct, seed_a, masked_a[i]);
                end

`ifdef SWAP_AW_DATA_PLACEMENT
                // Workload-placement ablation:
                //   keep A_SPARSITY_PCT/W_SPARSITY_PCT semantics on the original
                //   activation/weight data sources, but write masked activation
                //   rows to the DUT weight-side input and masked weight rows to
                //   the DUT activation-side input.
                sram_write(i[3:0], masked_a[i], masked_w[i]);
`else
                sram_write(i[3:0], masked_w[i], masked_a[i]);
`endif
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

    task automatic run_selected_workload;
        integer is_p8;
        integer mode_bit;
        integer op;
        integer n_ops;
        integer bcnt;
        integer addr;
        integer dense_macs;
        integer effective_macs;
        integer ok;
        reg [15:0] result;
        reg [31:0] cycles;
        reg [31:0] busy_cycles;
        integer dense_ops;
        integer effective_ops;
        begin
            is_p8 = (workload_arg == "p8_l1");
            mode_bit = is_p8 ? POSIT8 : POSIT16;

            load_mnist_hex();
            prepare_masked_rows(is_p8);

            n_ops = max_ops;
            if (n_ops > 8) n_ops = 8;
            if (n_ops < 1) n_ops = 1;

            $display("[WORKLOAD] dut=%0s workload=%0s a_sp=%0d w_sp=%0d seed=%0d max_ops=%0d",
                     `DUT_NAME, workload_arg, a_sparsity_pct, w_sparsity_pct,
                     mask_seed_base, n_ops);

`ifdef SWAP_AW_DATA_PLACEMENT
            $display("[WORKLOAD_SWAP_AW] enabled=1 semantics=A/W sparsity refer to original data; write placement is swapped.");
`else
            $display("[WORKLOAD_SWAP_AW] enabled=0");
`endif

            for (op = 0; op < n_ops; op = op + 1) begin
                get_meta(op, is_p8, bcnt, addr);

                if (is_p8)
                    count_p8_window(addr, bcnt, dense_macs, effective_macs);
                else
                    count_p16_window(addr, bcnt, dense_macs, effective_macs);

                dense_ops = dense_macs * 2;
                effective_ops = effective_macs * 2;

                run_mac_perf(mode_bit[0], bcnt[7:0], addr[3:0],
                             result, cycles, busy_cycles, ok);

                if (ok) pass_cnt = pass_cnt + 1;
                else    fail_cnt = fail_cnt + 1;

                $display("[PERF] dut=%0s workload=%0s op=%0d mode=%0s batch_cnt=%0d start_addr=%0d cycles=%0d busy_cycles=%0d dense_macs=%0d effective_macs=%0d dense_ops=%0d effective_ops=%0d result=%h status=%0s",
                         `DUT_NAME, workload_arg, op, is_p8 ? "P8" : "P16",
                         bcnt, addr, cycles, busy_cycles,
                         dense_macs, effective_macs, dense_ops, effective_ops,
                         result, ok ? "PASS" : "FAIL");

                if (perf_csv != 0) begin
                    $fwrite(perf_csv,
                            "%0s,%0s,%0s,%0d,%0d,%0d,%0d,%0s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%0s\n",
                            `DUT_NAME, `DUT_NAME, workload_arg,
                            a_sparsity_pct, w_sparsity_pct, mask_seed_base,
                            op, is_p8 ? "P8" : "P16", bcnt, addr,
                            cycles, busy_cycles,
                            dense_macs, effective_macs,
                            dense_ops, effective_ops, result,
                            ok ? "PASS" : "FAIL");
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
        if (!$value$plusargs("DATA_SOURCE_MODE=%d", data_source_mode))
            data_source_mode = 0;

        $display("[DATA_SOURCE_MODE] %0d (0=MNIST,1=SYNTH_DENSE,2=HYBRID)", data_source_mode);
        $dumpfile(`VCD_PATH);
        $dumpvars(0, tb_cim_top_mnist_sparse);
`ifdef ENERGY_COMPUTE_DUMP
        $dumpoff;
`endif

        perf_csv = $fopen(`PERF_CSV_PATH, "w");
        if (perf_csv != 0) begin
            $fwrite(perf_csv,
                    "design_key,dut,workload,a_sparsity_pct,w_sparsity_pct,seed,op_idx,mode,batch_cnt,start_addr,cycles,busy_cycles,dense_macs,effective_macs,dense_ops,effective_ops,result_hex,status\n");
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
        #(5000000);
        $display("[TB] FATAL: simulation watchdog expired");
        $finish;
    end

endmodule
