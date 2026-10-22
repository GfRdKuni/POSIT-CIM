#!/bin/bash
# ==============================================================================
# Script Name : run_batch_gls_posit_cim.sh
# Project     : posit_cim_28nm
# Purpose     : RTL behavioral simulation and post-synthesis SDF GLS for cim_top.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/run_batch_gls_posit_cim.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   bash run_batch_gls_posit_cim.sh rtl
#   bash run_batch_gls_posit_cim.sh gls
#
# Notes:
#   1. RTL simulation no longer uses +notimingcheck/+nospecify. Those switches
#      were previously needed for black-box memory/IP timing checks, but the
#      current server uses a handwritten posit_rf_16x128 replacement.
#   2. MNIST_REAL_DATA is enabled by default. The script assumes hex files are in:
#        ./testdata/*.hex
#      so run this script from the sim directory.
#   3. The clock port may still be named clk_333MHz_i in RTL/TB, but the clock
#      period is controlled by CLK_PERIOD_NS and is not tied to 3.0 ns.
#   4. Set USE_ILAUNCH=0 if you are already inside a compute-node allocation.
# ==============================================================================

set -u
set -o pipefail

# ------------------------------------------------------------------------------
# 1. Run-mode and user-overridable knobs
# ------------------------------------------------------------------------------
SIM_MODE=${1:-"gls"}                  # rtl | gls
TOP=${TOP:-"cim_top"}
TB_TOP=${TB_TOP:-"tb_cim_top"}

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
RTL_DIR=${RTL_DIR:-"${PROJ_ROOT}/rtl"}
SYN_DIR=${SYN_DIR:-"${PROJ_ROOT}/syn"}

TB_FILE=${TB_FILE:-"${SIM_DIR}/tb_cim_top.v"}
FILELIST=${FILELIST:-"${SIM_DIR}/filelist.f"}

# Slightly more aggressive than the old 3 ns memory-IP-driven setting.
# Override, for example:
#   CLK_PERIOD_NS=2.6 bash run_batch_gls_posit_cim.sh rtl
CLK_PERIOD_NS=${CLK_PERIOD_NS:-"2.8"}

# Enable MNIST real workload by default. Set ENABLE_MNIST=0 for quick smoke runs.
ENABLE_MNIST=${ENABLE_MNIST:-1}

# Use ilaunch by default for heavy VCS compile/run jobs.
USE_ILAUNCH=${USE_ILAUNCH:-1}
ILAUNCH_BIN=${ILAUNCH_BIN:-"ilaunch"}

# VCS binary and common options.
VCS_BIN=${VCS_BIN:-"vcs"}
VCS_COMMON_OPTS=${VCS_COMMON_OPTS:-"-full64 -sverilog +v2k -q -timescale=1ns/1ps"}

# Current new-server TSMC28HPC+ standard-cell Verilog model.
# Add extra LVT/HVT model files here later if mixed-Vt synthesis netlists require them.
STD_CELL_V=${STD_CELL_V:-"/path/to/licensed_pdk/tsmcN28/TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp30p140_110a/tcbn28hpcplusbwp30p140.v"}

# DesignWare simulation models. Keep this because multipliers/adders may infer DW cells.
if [ -z "${SYNOPSYS:-}" ]; then
    export SYNOPSYS="/tools/eda/synopsys/syn/T-2022.03-SP5-3"
fi
DW_SIM_DIR="${SYNOPSYS}/dw/sim_ver"

# ------------------------------------------------------------------------------
# 2. Helpers
# ------------------------------------------------------------------------------
run_heavy() {
    if [ "${USE_ILAUNCH}" = "1" ]; then
        "${ILAUNCH_BIN}" "$@"
    else
        "$@"
    fi
}

die() {
    echo "[FATAL] $*" >&2
    exit 1
}

check_file() {
    [ -f "$1" ] || die "File not found: $1"
}

check_dir() {
    [ -d "$1" ] || die "Directory not found: $1"
}

build_defines() {
    local defs=()
    defs+=("+define+CLK_PERIOD=${CLK_PERIOD_NS}")
    defs+=("+define+TB_FATAL_ON_FAIL")
    defs+=("+define+HAVE_REAL_RF_WRAPPER")
    if [ "${ENABLE_MNIST}" = "1" ]; then
        defs+=("+define+MNIST_REAL_DATA")
    fi
    printf "%s\n" "${defs[@]}"
}

build_rtl_inputs() {
    # Prefer a sim-local filelist because it gives deterministic order.
    # Fall back to all RTL Verilog files if filelist.f is not present yet.
    if [ -f "${FILELIST}" ]; then
        echo "-f"
        echo "${FILELIST}"
    else
        find "${RTL_DIR}" -maxdepth 1 -type f \( -name "*.v" -o -name "*.sv" \) | sort
    fi
}

print_config() {
    echo "----------------------------------------------------------------------"
    echo " Project root     : ${PROJ_ROOT}"
    echo " Simulation dir   : ${SIM_DIR}"
    echo " RTL dir          : ${RTL_DIR}"
    echo " Syn dir          : ${SYN_DIR}"
    echo " Testbench        : ${TB_FILE}"
    echo " Filelist         : ${FILELIST} $([ -f "${FILELIST}" ] && echo "(used)" || echo "(not found; using RTL_DIR/*.v)")"
    echo " TOP              : ${TOP}"
    echo " TB_TOP           : ${TB_TOP}"
    echo " CLK_PERIOD_NS    : ${CLK_PERIOD_NS}"
    echo " ENABLE_MNIST     : ${ENABLE_MNIST}"
    echo " USE_ILAUNCH      : ${USE_ILAUNCH}"
    echo " STD_CELL_V       : ${STD_CELL_V}"
    echo "----------------------------------------------------------------------"
}

# ------------------------------------------------------------------------------
# 3. Pre-flight
# ------------------------------------------------------------------------------
check_dir "${PROJ_ROOT}"
check_dir "${SIM_DIR}"
check_dir "${RTL_DIR}"
check_file "${TB_FILE}"

cd "${SIM_DIR}" || die "Cannot cd to ${SIM_DIR}"

if [ "${ENABLE_MNIST}" = "1" ]; then
    check_dir "${SIM_DIR}/testdata"
    if ! ls "${SIM_DIR}/testdata"/*.hex >/dev/null 2>&1; then
        die "ENABLE_MNIST=1 but no hex files found under ${SIM_DIR}/testdata"
    fi
fi

print_config

# ------------------------------------------------------------------------------
# 4. RTL behavioral simulation
# ------------------------------------------------------------------------------
if [ "${SIM_MODE}" = "rtl" ]; then
    echo "======================================================================"
    echo " [START] RTL Behavioral Simulation for ${TOP}"
    echo "======================================================================"

    SIM_WORK_DIR="${SIM_DIR}/sim_workspace_rtl"
    mkdir -p "${SIM_WORK_DIR}"

    SIM_EXEC="${SIM_WORK_DIR}/simv_rtl"
    COMP_LOG="${SIM_WORK_DIR}/vcs_compile_rtl.log"
    RUN_LOG="${SIM_WORK_DIR}/vcs_run_rtl.log"
    CSRC_DIR="${SIM_WORK_DIR}/csrc_rtl"
    VCD_PATH="${SIM_WORK_DIR}/tb_cim_top_rtl.vcd"

    mapfile -t DEFINES < <(build_defines)
    mapfile -t RTL_INPUTS < <(build_rtl_inputs)

    echo "  [1/2] Compiling RTL source codes..."
    # No +notimingcheck/+nospecify here: current RF is handwritten logic,
    # not the old black-box/memory-IP model that required timing-check masking.
    run_heavy "${VCS_BIN}" ${VCS_COMMON_OPTS} \
        "${DEFINES[@]}" \
        "+define+VCD_PATH=\"${VCD_PATH}\"" \
        "${TB_FILE}" "${RTL_INPUTS[@]}" \
        -y "${DW_SIM_DIR}" +libext+.v \
        -top "${TB_TOP}" \
        -Mdir="${CSRC_DIR}" \
        -l "${COMP_LOG}" \
        -o "${SIM_EXEC}"

    if [ $? -ne 0 ]; then
        echo "  [ERR] RTL compilation failed. See ${COMP_LOG}"
        exit 1
    fi

    echo "  [2/2] Running RTL behavioral simulation..."
    run_heavy "${SIM_EXEC}" -l "${RUN_LOG}" -q
    sim_rc=$?

    if [ ${sim_rc} -ne 0 ]; then
        echo "  [FAIL] RTL simulation exited with non-zero status ${sim_rc}. See ${RUN_LOG}"
        exit ${sim_rc}
    fi

    if grep -q "\[TB\] OVERALL: PASS" "${RUN_LOG}"; then
        echo "  [OK] RTL simulation PASSED. Logs: ${SIM_WORK_DIR}"
        exit 0
    else
        echo "  [FAIL] RTL simulation did not report OVERALL PASS. See ${RUN_LOG}"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 5. Post-synthesis gate-level simulation with SDF
# ------------------------------------------------------------------------------
if [ "${SIM_MODE}" = "gls" ]; then
    echo "======================================================================"
    echo " [START] Multi-Corner Post-Synthesis GLS for ${TOP}"
    echo "======================================================================"

    check_file "${STD_CELL_V}"

    # Corner list should match synthesis output directory names:
    #   ${SYN_DIR}/outputs_${CORNER}/${TOP}_${CORNER}.v
    #   ${SYN_DIR}/outputs_${CORNER}/${TOP}_${CORNER}.sdf
    #
    # Override from shell if needed:
    #   CORNERS="tt0p9v25c ssg0p81vm40c" bash run_batch_gls_posit_cim.sh gls
    if [ -n "${CORNERS:-}" ]; then
        read -r -a CORNER_LIST <<< "${CORNERS}"
    else
        CORNER_LIST=(
            "ffg_0p99v_0p99v_125c"
            "ffg_1p05v_0p99v_125c"
            "ffg_1p05v_1p05v_125c"
            "ssg_0p72v_0p72v_0c"
            "ssg_0p72v_0p72v_125c"
            "ssg_0p72v_0p72v_m40c"
            "ssg_0p72v_0p81v_0c"
            "ssg_0p72v_0p81v_125c"
            "ssg_0p72v_0p81v_m40c"
            "ssg_0p81v_0p81v_0c"
            "ssg_0p81v_0p81v_125c"
            "ssg_0p81v_0p81v_m40c"
            "ssg_0p90v_0p81v_0c"
            "ssg_0p90v_0p81v_125c"
            "ssg_0p90v_0p81v_m40c"
            "ssg_0p90v_0p90v_0c"
            "ssg_0p90v_0p90v_125c"
            "ssg_0p90v_0p90v_m40c"
            "tt_0p90v_0p90v_25c"
            "tt_0p90v_0p90v_85c"
            "tt_1p00v_0p90v_85c"
            "tt_1p05v_0p90v_85c"
        )
    fi

    declare -A RESULTS
    total_corners=${#CORNER_LIST[@]}
    current_idx=0

    mapfile -t BASE_DEFINES < <(build_defines)

    for CORNER in "${CORNER_LIST[@]}"; do
        ((current_idx++))
        echo ""
        echo ">>> Processing corner [${current_idx}/${total_corners}]: ${CORNER}"

        SYN_OUTPUT_DIR="${SYN_DIR}/outputs_${CORNER}"
        NETLIST="${SYN_OUTPUT_DIR}/${TOP}_${CORNER}.v"
        SDF_FILE="${SYN_OUTPUT_DIR}/${TOP}_${CORNER}.sdf"

        SIM_WORK_DIR="${SIM_DIR}/sim_workspace_${CORNER}"
        mkdir -p "${SIM_WORK_DIR}"

        SIM_EXEC="${SIM_WORK_DIR}/simv_${CORNER}"
        COMP_LOG="${SIM_WORK_DIR}/vcs_compile_${CORNER}.log"
        RUN_LOG="${SIM_WORK_DIR}/vcs_run_${CORNER}.log"
        CSRC_DIR="${SIM_WORK_DIR}/csrc_${CORNER}"
        VCD_PATH="${SIM_WORK_DIR}/tb_cim_top_${CORNER}.vcd"

        if [ ! -f "${NETLIST}" ] || [ ! -f "${SDF_FILE}" ]; then
            echo "  [SKIP] Missing netlist or SDF:"
            echo "         NETLIST=${NETLIST}"
            echo "         SDF=${SDF_FILE}"
            RESULTS[$CORNER]="SKIPPED (missing netlist/SDF)"
            continue
        fi

        echo "  [1/2] Compiling gate-level netlist with SDF macro..."
        # GLS keeps negative timing/delay support, but does not globally mask timing checks.
        # If a specific corner exposes expected benign library timing warnings, handle that
        # later case-by-case instead of hiding all checks.
        run_heavy "${VCS_BIN}" ${VCS_COMMON_OPTS} \
            +neg_tchk +negdelay \
            "${BASE_DEFINES[@]}" \
            +define+POST_SYN \
            "+define+SDF_PATH=\"${SDF_FILE}\"" \
            "+define+VCD_PATH=\"${VCD_PATH}\"" \
            "${TB_FILE}" "${NETLIST}" \
            -v "${STD_CELL_V}" \
            -y "${DW_SIM_DIR}" +libext+.v \
            -top "${TB_TOP}" \
            -Mdir="${CSRC_DIR}" \
            -l "${COMP_LOG}" \
            -o "${SIM_EXEC}"

        if [ $? -ne 0 ]; then
            echo "  [ERR] GLS compilation failed. See ${COMP_LOG}"
            RESULTS[$CORNER]="COMPILE ERROR"
            continue
        fi

        echo "  [2/2] Running SDF back-annotated simulation..."
        run_heavy "${SIM_EXEC}" -l "${RUN_LOG}" -q
        sim_rc=$?

        if [ ${sim_rc} -ne 0 ]; then
            echo "  [FAIL] Simulation exited with non-zero status ${sim_rc}. See ${RUN_LOG}"
            RESULTS[$CORNER]="FAIL (non-zero exit)"
            continue
        fi

        if grep -q "\[TB\] OVERALL: PASS" "${RUN_LOG}"; then
            echo "  [OK] GLS PASSED."
            RESULTS[$CORNER]="PASS"
        else
            echo "  [FAIL] GLS did not report OVERALL PASS. See ${RUN_LOG}"
            RESULTS[$CORNER]="FAIL"
        fi
    done

    SUMMARY="${SIM_DIR}/gls_summary_${TOP}.rpt"
    {
        echo "======================================================================"
        echo " Multi-Corner GLS Summary for ${TOP}"
        echo " CLK_PERIOD_NS=${CLK_PERIOD_NS}, ENABLE_MNIST=${ENABLE_MNIST}"
        echo "======================================================================"
        for CORNER in "${CORNER_LIST[@]}"; do
            printf "  %-28s : %s\n" "$CORNER" "${RESULTS[$CORNER]:-NOT_RUN}"
        done
        echo "======================================================================"
    } | tee "${SUMMARY}"

    echo "Summary written to ${SUMMARY}"
    exit 0
fi

die "Invalid mode: ${SIM_MODE}. Please use rtl or gls."
