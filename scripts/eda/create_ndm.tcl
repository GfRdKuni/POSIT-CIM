# ======================================================================
# Script Name: create_ndm.tcl
# Description: 统一从 Milkyway 库提取 FRAM 视图，生成 NDM 物理时序库
# ======================================================================
catch {close_workspace}

set TSMC_DB_ROOT "/tools/lib/CLN28HPC+/SC/digital/Front_End/timing_power_noise/CCS"
set TSMC_BACKEND "/tools/lib/eda/library/tsmc/tsmc28hpcplus-lite/TSMCHOME/digital/Back_End"
set RF_ROOT      "/path/to/user/workspace/posit/hw/ip/posit_rf_16x128"

set CORNER       "tt_0p90v_0p90v_25c"
set LVT_CORNER   "tt0p9v25c"
set TECH_FILE    "${TSMC_BACKEND}/ICC_techfile/PRTF_ICC_28nm_Syn_V19_1a/PR_tech/Synopsys/TechFile/HVH/tsmcn28_9lm6X2ZRDL.tf"

# ------------------------------------------------------------------------------
# 1. 转换标准逻辑单元库 (LVT) - 纯 Milkyway 提取流
# ------------------------------------------------------------------------------
puts "\n---> [1/2] Compiling Standard Cell LVT NDM from Milkyway FRAM..."
file delete -force stdcell_lvt.ndm
create_workspace stdcell_lvt.ndm -technology $TECH_FILE

set MW_LVT "${TSMC_BACKEND}/milkyway/tcbn28hpcplusbwp7t35p140lvt_110a/cell_frame_HVH_0d5_0/tcbn28hpcplusbwp7t35p140lvt"
set DB_LVT "${TSMC_DB_ROOT}/tcbn28hpcplusbwp7t35p140lvt_180a/tcbn28hpcplusbwp7t35p140lvt${LVT_CORNER}_ccs.db"

if {![file isdirectory $MW_LVT]} {
    puts "\[FATAL\] LVT Milkyway Lib not found: $MW_LVT !"
    exit 1
}

puts "\[INFO\] Reading LVT Timing DB : $DB_LVT"
read_db $DB_LVT

puts "\[INFO\] Extracting FRAM from LVT Milkyway Lib: $MW_LVT"
generate_frame_from_mw -mw_lib $MW_LVT stdcell_lvt.ndm

check_workspace
commit_workspace
close_workspace

# ------------------------------------------------------------------------------
# 2. 转换 RF 宏单元 - 纯 Milkyway 提取流
# ------------------------------------------------------------------------------
puts "\n---> [2/2] Compiling POSIT RF Macro NDM from Milkyway FRAM..."
file delete -force posit_rf_16x128.ndm
create_workspace posit_rf_16x128.ndm -technology $TECH_FILE

set MW_RF "${RF_ROOT}/posit_rf_16x128_mw"
set DB_RF "${RF_ROOT}/posit_rf_16x128_${CORNER}.db"

if {![file isdirectory $MW_RF]} {
    puts "\[FATAL\] RF Milkyway Lib not found: $MW_RF !"
    exit 1
}

puts "\[INFO\] Reading RF Timing DB : $DB_RF"
read_db $DB_RF

puts "\[INFO\] Extracting FRAM from RF Milkyway Lib: $MW_RF"
generate_frame_from_mw -mw_lib $MW_RF posit_rf_16x128.ndm

check_workspace
commit_workspace
close_workspace

puts "\n======================================================================"
puts " \[SUCCESS\] All NDM libraries successfully generated from Milkyway FRAM!"
puts "======================================================================"
exit
