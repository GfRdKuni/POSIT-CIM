#!/bin/bash
# ==============================================================================
# Script Name : run_chip_sim.sh
# Project     : posit_cim_28nm
# Purpose     : RTL behavioral simulation and post-synthesis SDF GLS for cim_chip.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/run_chip_sim.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x run_chip_sim.sh
#   ilaunch ./run_chip_sim.sh rtl
#   ilaunch ./run_chip_sim.sh gls
#
# Notes:
#   1. This script does NOT call ilaunch internally. Submit it from outside:
#        ilaunch ./run_chip_sim.sh rtl
#   2. RTL simulation no longer uses +notimingcheck/+nospecify. Those switches
#      were mainly for the old black-box memory/IP flow.
#   3. MNIST_REAL_DATA is enabled by default. Hex files are expected under:
#        ./testdata/*.hex
#   4. The clock port may still be named clk_333MHz_i, but the clock period is
#      controlled by CLK_PERIOD_NS and is not forced to 3.0 ns.
# ==============================================================================

set -u
set -o pipefail

# ------------------------------------------------------------------------------
# 1. Run-mode and user-overridable knobs
# ------------------------------------------------------------------------------
SIM_MODE=${1:-"rtl"}                  # rtl | gls

TOP=${TOP:-"cim_chip"}
TB_TOP=${TB_TOP:-"tb_cim_chip"}

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
RTL_DIR=${RTL_DIR:-"${PROJ_ROOT}/rtl"}
SYN_DIR=${SYN_DIR:-"${PROJ_ROOT}/syn"}

TB_FILE=${TB_FILE:-"${SIM_DIR}/tb_cim_chip.v"}
FILELIST=${FILELIST:-"${SIM_DIR}/filelist_chip.f"}

# Slightly more aggressive than the old 3 ns memory-IP-driven setting.
# Override example:
#   CLK_PERIOD_NS=2.6 ilaunch ./run_chip_sim.sh rtl
CLK_PERIOD_NS=${CLK_PERIOD_NS:-"2.8"}

# Enable MNIST real workload by default. Set ENABLE_MNIST=0 for quick tests.
ENABLE_MNIST=${ENABLE_MNIST:-1}

# VCS binary and common options.
VCS_BIN=${VCS_BIN:-"vcs"}
VCS_COMMON_OPTS=${VCS_COMMON_OPTS:-"-full64 -sverilog +v2k -q -timescale=1ns/1ps"}

# Current new-server TSMC28HPC+ standard-cell Verilog model.
# If later mixed-Vt gate-level netlists instantiate LVT/HVT cells from additional
# libraries, add their Verilog models through EXTRA_STD_CELL_V.
STD_CELL_V=${STD_CELL_V:-"/path/to/licensed_pdk/tsmcN28/TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp30p140_110a/tcbn28hpcplusbwp30p140.v"}
EXTRA_STD_CELL_V=${EXTRA_STD_CELL_V:-""}

# DesignWare simulation models.
if [ -z "${SYNOPSYS:-}" ]; then
    export SYNOPSYS="/tools/eda/synopsys/syn/T-2022.03-SP5-3"
fi
DW_SIM_DIR="${SYNOPSYS}/dw/sim_ver"

# ------------------------------------------------------------------------------
# 2. Helpers
# ------------------------------------------------------------------------------
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
    # Prefer a chip-specific sim-local filelist because it gives deterministic
    # compile order. Fall back to all RTL Verilog/SystemVerilog files.
    if [ -f "${FILELIST}" ]; then
        echo "-f"
        echo "${FILELIST}"
    elif [ -f "${SIM_DIR}/filelist.f" ]; then
        echo "-f"
        echo "${SIM_DIR}/filelist.f"
    else
        find "${RTL_DIR}" -maxdepth 1 -type f \( -name "*.v" -o -name "*.sv" \) | sort
    fi
}

build_std_cell_inputs() {
    local files=()
    files+=("${STD_CELL_V}")
    if [ -n "${EXTRA_STD_CELL_V}" ]; then
        # shellcheck disable=SC2206
        local extra=( ${EXTRA_STD_CELL_V} )
        files+=("${extra[@]}")
    fi

    local f
    for f in "${files[@]}"; do
        check_file "${f}"
        echo "-v"
        echo "${f}"
    done
}

print_config() {
    echo "----------------------------------------------------------------------"
    echo " Project root     : ${PROJ_ROOT}"
    echo " Simulation dir   : ${SIM_DIR}"
    echo " RTL dir          : ${RTL_DIR}"
    echo " Syn dir          : ${SYN_DIR}"
    echo " Testbench        : ${TB_FILE}"
    if [ -f "${FILELIST}" ]; then
        echo " Filelist         : ${FILELIST} (used)"
    elif [ -f "${SIM_DIR}/filelist.f" ]; then
        echo " Filelist         : ${SIM_DIR}/filelist.f (used fallback)"
    else
        echo " Filelist         : ${FILELIST} (not found; using RTL_DIR/*.v)"
    fi
    echo " TOP              : ${TOP}"
    echo " TB_TOP           : ${TB_TOP}"
    echo " CLK_PERIOD_NS    : ${CLK_PERIOD_NS}"
    echo " ENABLE_MNIST     : ${ENABLE_MNIST}"
    echo " STD_CELL_V       : ${STD_CELL_V}"
    if [ -n "${EXTRA_STD_CELL_V}" ]; then
        echo " EXTRA_STD_CELL_V : ${EXTRA_STD_CELL_V}"
    fi
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

    SIM_WORK_DIR="${SIM_DIR}/sim_workspace_chip_rtl"
    mkdir -p "${SIM_WORK_DIR}"

    SIM_EXEC="${SIM_WORK_DIR}/simv_chip_rtl"
    COMP_LOG="${SIM_WORK_DIR}/vcs_compile_chip_rtl.log"
    RUN_LOG="${SIM_WORK_DIR}/vcs_run_chip_rtl.log"
    CSRC_DIR="${SIM_WORK_DIR}/csrc_chip_rtl"
    VCD_PATH="${SIM_WORK_DIR}/tb_cim_chip_rtl.vcd"

    mapfile -t DEFINES < <(build_defines)
    mapfile -t RTL_INPUTS < <(build_rtl_inputs)

    echo "  [1/2] Compiling RTL source codes..."
    # Do not add +notimingcheck/+nospecify for RTL behavior simulation.
    "${VCS_BIN}" ${VCS_COMMON_OPTS} \
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
    "${SIM_EXEC}" -l "${RUN_LOG}" -q
    sim_rc=$?

    if [ ${sim_rc} -ne 0 ]; then
        echo "  [FAIL] RTL simulation exited with non-zero status ${sim_rc}. See ${RUN_LOG}"
        exit ${sim_rc}
    fi

    if grep -q "\[TB\] OVERALL: PASS" "${RUN_LOG}"; then
        echo "  [OK] RTL chip simulation PASSED. Logs: ${SIM_WORK_DIR}"
        exit 0
    else
        echo "  [FAIL] RTL chip simulation did not report OVERALL PASS. See ${RUN_LOG}"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 5. Post-synthesis gate-level simulation with SDF
# ------------------------------------------------------------------------------
if [ "${SIM_MODE}" = "gls" ]; then
    echo "======================================================================"
    echo " [START] Post-Synthesis Gate-Level Simulation for ${TOP}"
    echo "======================================================================"

    CORNER=${CORNER:-"tt_0p90v_0p90v_25c"}
    SYN_OUTPUT_DIR=${SYN_OUTPUT_DIR:-"${SYN_DIR}/outputs_chip_${CORNER}"}
    NETLIST=${NETLIST:-"${SYN_OUTPUT_DIR}/${TOP}_${CORNER}.v"}
    SDF_FILE=${SDF_FILE:-"${SYN_OUTPUT_DIR}/${TOP}_${CORNER}.sdf"}

    check_file "${NETLIST}"
    check_file "${SDF_FILE}"

    SIM_WORK_DIR="${SIM_DIR}/sim_workspace_chip_gls_${CORNER}"
    mkdir -p "${SIM_WORK_DIR}"

    SIM_EXEC="${SIM_WORK_DIR}/simv_chip_gls_${CORNER}"
    COMP_LOG="${SIM_WORK_DIR}/vcs_compile_chip_gls_${CORNER}.log"
    RUN_LOG="${SIM_WORK_DIR}/vcs_run_chip_gls_${CORNER}.log"
    CSRC_DIR="${SIM_WORK_DIR}/csrc_chip_gls_${CORNER}"
    VCD_PATH="${SIM_WORK_DIR}/tb_cim_chip_gls_${CORNER}.vcd"

    mapfile -t BASE_DEFINES < <(build_defines)
    mapfile -t STD_CELL_INPUTS < <(build_std_cell_inputs)

    echo "  [INFO] Corner  : ${CORNER}"
    echo "  [INFO] Netlist : ${NETLIST}"
    echo "  [INFO] SDF     : ${SDF_FILE}"

    echo "  [1/2] Compiling gate-level netlist with SDF macro..."
    "${VCS_BIN}" ${VCS_COMMON_OPTS} \
        +neg_tchk +negdelay \
        "${BASE_DEFINES[@]}" \
        +define+POST_SYN \
        "+define+SDF_PATH=\"${SDF_FILE}\"" \
        "+define+VCD_PATH=\"${VCD_PATH}\"" \
        "${TB_FILE}" "${NETLIST}" \
        "${STD_CELL_INPUTS[@]}" \
        -y "${DW_SIM_DIR}" +libext+.v \
        -top "${TB_TOP}" \
        -Mdir="${CSRC_DIR}" \
        -l "${COMP_LOG}" \
        -o "${SIM_EXEC}"

    if [ $? -ne 0 ]; then
        echo "  [ERR] GLS compilation failed. See ${COMP_LOG}"
        exit 1
    fi

    echo "  [2/2] Running SDF back-annotated simulation..."
    "${SIM_EXEC}" -l "${RUN_LOG}" -q
    sim_rc=$?

    if [ ${sim_rc} -ne 0 ]; then
        echo "  [FAIL] GLS simulation exited with non-zero status ${sim_rc}. See ${RUN_LOG}"
        exit ${sim_rc}
    fi

    grep -E "SDF Annotation|Doing SDF annotation|\[TB\] OVERALL:" "${RUN_LOG}" || true

    if grep -q "\[TB\] OVERALL: PASS" "${RUN_LOG}"; then
        echo "  [OK] GLS chip simulation PASSED. Logs: ${SIM_WORK_DIR}"
        exit 0
    else
        echo "  [FAIL] GLS chip simulation did not report OVERALL PASS. See ${RUN_LOG}"
        exit 1
    fi
fi

die "Invalid mode: ${SIM_MODE}. Please use rtl or gls."
