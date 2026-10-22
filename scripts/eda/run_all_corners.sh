#!/bin/bash
# ==============================================================================
# Script Name : run_all_corners.sh
# Project     : posit_cim_28nm
# Purpose     : Multi-corner non-SPG DC synthesis for cim_top.
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/syn
#   chmod +x run_all_corners.sh
#   ilaunch ./run_all_corners.sh
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. The old flow used dc_shell -topo and compile_ultra -spg. This version uses
#      ordinary dc_shell and compile_ultra because SPG/topographical assets are
#      not assumed to be available on the new server.
#   3. CLK_PERIOD is a synthesis/SDF timing constraint. It is not inferred from
#      the RTL testbench period.
# ==============================================================================

set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SYN_DIR=${SYN_DIR:-"${PROJ_ROOT}/syn"}
TCL_SCRIPT=${TCL_SCRIPT:-"${SYN_DIR}/syn.tcl"}

DC_BIN=${DC_BIN:-"dc_shell"}

# Try slightly more aggressive than the old memory-IP-driven 3.0 ns.
# Override example:
#   CLK_PERIOD=2.6 ilaunch ./run_all_corners.sh
CLK_PERIOD=${CLK_PERIOD:-"2.8"}

# Optional quick controls:
#   RUN_PHASE1=0 ilaunch ./run_all_corners.sh    # skip full sweep
#   RUN_PHASE2=0 ilaunch ./run_all_corners.sh    # skip hierarchy sweep
RUN_PHASE1=${RUN_PHASE1:-1}
RUN_PHASE2=${RUN_PHASE2:-1}

mkdir -p "${SYN_DIR}"
cd "${SYN_DIR}"

if [ ! -f "${TCL_SCRIPT}" ]; then
    echo "[FATAL] Missing Tcl script: ${TCL_SCRIPT}" >&2
    exit 1
fi

echo "================================================================="
echo " Project root : ${PROJ_ROOT}"
echo " Syn dir      : ${SYN_DIR}"
echo " Tcl script   : ${TCL_SCRIPT}"
echo " DC binary    : ${DC_BIN}"
echo " CLK_PERIOD   : ${CLK_PERIOD} ns"
echo " RUN_PHASE1   : ${RUN_PHASE1}"
echo " RUN_PHASE2   : ${RUN_PHASE2}"
echo "================================================================="

# ------------------------------------------------------------------------------
# Phase 1: full optimized multi-corner sweep
# ------------------------------------------------------------------------------
PAIRS_FULL=(
    "ffg,0p99v,0p99v,125c"
    "ffg,1p05v,0p99v,125c"
    "ffg,1p05v,1p05v,125c"
    "ssg,0p72v,0p72v,0c"
    "ssg,0p72v,0p72v,125c"
    "ssg,0p72v,0p72v,m40c"
    "ssg,0p72v,0p81v,0c"
    "ssg,0p72v,0p81v,125c"
    "ssg,0p72v,0p81v,m40c"
    "ssg,0p81v,0p81v,0c"
    "ssg,0p81v,0p81v,125c"
    "ssg,0p81v,0p81v,m40c"
    "ssg,0p90v,0p81v,0c"
    "ssg,0p90v,0p81v,125c"
    "ssg,0p90v,0p81v,m40c"
    "ssg,0p90v,0p90v,0c"
    "ssg,0p90v,0p90v,125c"
    "ssg,0p90v,0p90v,m40c"
    "tt,0p90v,0p90v,25c"
    "tt,0p90v,0p90v,85c"
    "tt,1p00v,0p90v,85c"
    "tt,1p05v,0p90v,85c"
)

# ------------------------------------------------------------------------------
# Phase 2: hierarchy-preserved representative corners
# ------------------------------------------------------------------------------
PAIRS_HIER=(
    "tt,0p90v,0p90v,25c"
    "ssg,0p81v,0p81v,125c"
    "ffg,0p99v,0p99v,125c"
)

run_one_corner() {
    local combo="$1"
    local keep_hier="$2"
    local suffix="$3"

    IFS=',' read -r c vpe vce t <<< "${combo}"
    local full_corner="${c}_${vpe}_${vce}_${t}"
    local log_file="syn_${full_corner}${suffix}.log"

    echo ""
    echo "-----------------------------------------------------------------"
    echo " Running corner=${full_corner}, KEEP_HIER=${keep_hier}, CLK=${CLK_PERIOD}ns"
    echo " Log: ${log_file}"
    echo "-----------------------------------------------------------------"

    "${DC_BIN}" \
        -x "set CORNER ${c}; set VPE ${vpe}; set VOLTAGE ${vce}; set TEMP ${t}; set RF_CORNER ${full_corner}; set KEEP_HIER ${keep_hier}; set CLK_PERIOD ${CLK_PERIOD}" \
        -f "${TCL_SCRIPT}" | tee "${log_file}"

    local rc=${PIPESTATUS[0]}

    if grep -q "========== Corner .* done ==========" "${log_file}"; then
        echo "  [+] Corner ${full_corner}${suffix} completed successfully."
        return 0
    elif [ ${rc} -eq 2 ]; then
        echo "  [~] Corner ${full_corner}${suffix} skipped due to missing DB."
        return 0
    else
        echo "  [-] ERROR: Corner ${full_corner}${suffix} failed. Check ${log_file}"
        return 1
    fi
}

fail_count=0

if [ "${RUN_PHASE1}" = "1" ]; then
    echo ""
    echo "================================================================="
    echo " [PHASE 1] Full optimized non-SPG synthesis sweep"
    echo "================================================================="
    for combo in "${PAIRS_FULL[@]}"; do
        if ! run_one_corner "${combo}" 0 ""; then
            fail_count=$((fail_count + 1))
        fi
    done
fi

if [ "${RUN_PHASE2}" = "1" ]; then
    echo ""
    echo "================================================================="
    echo " [PHASE 2] Hierarchy-preserved synthesis for breakdown"
    echo "================================================================="
    for combo in "${PAIRS_HIER[@]}"; do
        if ! run_one_corner "${combo}" 1 "_hier"; then
            fail_count=$((fail_count + 1))
            continue
        fi

        IFS=',' read -r c vpe vce t <<< "${combo}"
        full_corner="${c}_${vpe}_${vce}_${t}"

        if [ -d "reports_${full_corner}" ]; then
            rm -rf "reports_${full_corner}_hier"
            mv "reports_${full_corner}" "reports_${full_corner}_hier"
        fi
        if [ -d "outputs_${full_corner}" ]; then
            rm -rf "outputs_${full_corner}_hier"
            mv "outputs_${full_corner}" "outputs_${full_corner}_hier"
        fi

        echo "  [i] Hierarchy reports moved to reports_${full_corner}_hier/"
        echo "  [i] Hierarchy outputs moved to outputs_${full_corner}_hier/"
    done
fi

echo ""
echo "================================================================="
if [ ${fail_count} -eq 0 ]; then
    echo " [DONE] All requested synthesis runs finished without script-level failure."
else
    echo " [DONE] Synthesis runs finished with ${fail_count} failed corner(s)."
fi
echo "================================================================="

exit ${fail_count}
