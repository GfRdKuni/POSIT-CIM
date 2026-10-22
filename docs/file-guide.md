# 文件导航

## 当前模块

| 路径 | 用途 |
|---|---|
| `rtl/a2c_pd.v` | POSIT 补码解码 |
| `rtl/msa_dcm.v` | 稀疏感知动态周期乘法 |
| `rtl/tc_bwc_mf.v` | 多路指数逐位寻大 |
| `rtl/weight_encode.v` | 权重 Booth 编码与零组信息 |
| `rtl/act_lut_setup.v` | 激活查找表准备 |
| `rtl/encode_collect.v` | 周期统计 |
| `rtl/exponent_adder.v` | 指数计算 |
| `rtl/adder_tree.v` | 加法树 |
| `rtl/posit_encoder.v` | 结果重编码 |
| `rtl/posit_cim_storage_dp.v` | 存储端口逻辑，依赖待补独立 wrapper |
| `rtl/posit_rf_16x128.v` | 手写寄存器堆 |

当前目录名用于区分归档中的主要副本，不表示已完成整套设计集成验证。历史接口和修订版本见 [archive](../archive/README.md)。

## 测试平台

`testbench/` 包含单核、多核和 MNIST 稀疏注入测试平台。`tb_cim_top_dutmacro.v`、`tb_cim_top.v` 以及几个 MNIST 变体可能声明相同模块名；应按目标选择一个测试平台，不要把目录下所有 `.v` 一次性送入编译器。部分测试平台内嵌行为存储 wrapper，也不能同时重复编译。

MNIST 稀疏测试会读取 `testdata/*.hex`。这些数据未归档；完整 DUT 顶层亦缺失。因此当前不能提供可直接通过的整套仿真命令。

## EDA 流程

`scripts/eda/` 保存原有综合、门级仿真、布局布线、时序/功耗与 hold ECO 脚本。

| 脚本族 | 用途 |
|---|---|
| `syn*.tcl`、`run_chip_syn.sh`、`run_all_corners.sh` | 综合和工艺角流程 |
| `run_*gls*.sh`、`run_chip_sim.sh` | SDF/门级仿真 |
| `run_innovus*.tcl`、`run_innovus*.sh` | 后端布局布线 |
| `run_energy*.sh`、`make_power_sessions_cleanfreq.sh` | 活动与功耗分析 |
| `hold_eco*.tcl`、`run_hold_eco*.sh` | hold 修复流程 |

这是按用途整理的脚本归档。原脚本仍假定部署目录内存在 `rtl/`、`syn/`、`sim/`、`pnr/` 等工作目录，并可能调用当前仓库未保存的辅助文件。使用前须审查路径、所需文件和文件覆盖行为。`/path/to/...` 是明确占位路径，需要使用者配置。

`clean_periods.tsv` 的源文件明确说明数值是 **placeholder**，待最终时序清理结果更新，不能当作最终 Fmax/时序结果。

## 实验分析

`scripts/analysis/` 保留以下 Python 入口及能耗汇总/扫描脚本。

| Python 入口 | 用途 |
|---|---|
| `extract_favorable_evidence.py` | 提取面积、功耗和消融对照；输出选择须结合完整结果判断 |
| `extract_sparsity_trends.py` | 提取稀疏扫描趋势 |
| `plot_sparsity_evidence_v6.py` | 绘制稀疏趋势图 |
| `visualize_deep_module_area_fixed_v3.py` | 模块面积可视化 |
| `visualize_energy_summary.py` | 能耗汇总可视化 |

这些脚本使用 NumPy、pandas、Matplotlib 等 Python 包。所选版本用于呈现当前材料中的分析入口，未证明可替代所有旧版本。运行通常需要外部结果表，详见各脚本的参数与开头说明。

## 图表与来源

`docs/figures/` 保存 12 张精选架构、算法和实验图。[source-map.csv](source-map.csv) 记录各文件的原始相对位置及公开副本处理方式。
