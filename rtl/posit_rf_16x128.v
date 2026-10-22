`timescale 1ns/1ps
// =============================================================================
// Module Name: posit_rf_16x128
// Description: 可综合行为模型，替代 MC2 生成的 TSMC 28nm 16x128 单端口高速寄存器堆
//              (RF) 宏单元。端口列表与 posit_cim_storage_wrapper 中的实例化保持
//              一致，仅保留功能/时序边带必需端口。
//
// 时序约定 (与 posit_cim_storage_dp.v 中的 sram_data_vld 流水匹配):
//   * 同步单端口，所有操作在 clk 上升沿采样。
//   * cen=1 时空操作 (NOP)，q 保持上一次的值。
//   * cen=0 且 wen=0 时执行写: mem[a] <= d，本拍 q 不更新 (write-no-read)。
//   * cen=0 且 wen=1 时执行读: q <= mem[a]，1 拍读延迟。
//   * ret1n=0 进入数据保持模式，功能上等价于禁止读写，q 保持不变。
//   * ema/emaw/emas 仅影响实际工艺时序，行为模型中忽略。
//
// Synthesis note:
//   * 不使用 === / !==，避免 Design Compiler 报 VER-189。
//   * 对 X/Z 控制信号不做仿真期 x-propagation 建模；综合语义以 0/1 二态为准。
// =============================================================================
module posit_rf_16x128 (
    input  wire         clk,
    input  wire         cen,        // chip enable, active low
    input  wire         wen,        // write enable, active low
    input  wire [3:0]   a,          // address (16 deep)
    input  wire [127:0] d,          // write data
    output reg  [127:0] q,          // read data, 1-cycle latency

    // Extra-margin / timing-compensation pins (functional-sim no-op)
    input  wire [2:0]   ema,
    input  wire [1:0]   emaw,
    input  wire         emas,

    // Retention control (active low)
    input  wire         ret1n
);

    reg [127:0] mem [0:15];
    integer i;

    initial begin
        for (i = 0; i < 16; i = i + 1) begin
            mem[i] = 128'd0;
        end
        q = 128'd0;
    end

    // Single-port synchronous RF:
    //   - read has 1-cycle latency because q is registered on posedge clk;
    //   - write-no-read because q is intentionally not assigned on write cycle;
    //   - retention/NOP hold q by leaving q unassigned in the clocked block.
    always @(posedge clk) begin
        if (ret1n == 1'b0) begin
            // Retention mode: hold contents, no read/write, q unchanged.
        end
        else if (cen == 1'b0) begin
            if (wen == 1'b0) begin
                mem[a] <= d;
                // q holds previous value on a write cycle.
            end
            else begin
                // wen == 1'b1 in normal 2-state synthesis semantics.
                q <= mem[a];
            end
        end
        // cen=1: NOP, q holds previous value.
    end

endmodule
