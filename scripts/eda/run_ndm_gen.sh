#!/bin/bash
# ======================================================================
# Script Name: run_ndm_gen.sh
# Description: 建立 Milkyway 伪装环境，并启动 icc2_lm_shell 生成 NDM
# ======================================================================

echo "======================================================================"
echo " [PHASE 0] Preparing Headless Executable Environment"
echo "======================================================================"

# 1. 创建假的 bin 目录
mkdir -p ./.fake_bin

# 2. 将您系统中的大写 Milkyway 强行软链接为工具底层写死的小写名字
REAL_MW_PATH="/tools/eda/synopsys/milkyway/P-2019.03-SP5-1/bin/AMD.64/Milkyway"

ln -sf $REAL_MW_PATH ./.fake_bin/milkyway
ln -sf $REAL_MW_PATH ./.fake_bin/icc_shell

echo " [INFO] Spoofed executables created in ./.fake_bin"

# 3. 劫持系统 PATH，将伪装目录提升至最高优先级
export PATH="$(pwd)/.fake_bin:$PATH"

echo " [INFO] PATH hijacked. Sub-processes will now find 'milkyway'."
echo "======================================================================"
echo " [PHASE 1] Launching ICC2 Library Manager"
echo "======================================================================"

# 4. 启动 Library Manager 执行纯 MW 转换脚本
icc2_lm_shell -f create_ndm.tcl

# 5. 清理伪装环境
rm -rf ./.fake_bin
echo "======================================================================"
echo " [SUCCESS] NDM Generation Flow Concluded."
echo "======================================================================"
