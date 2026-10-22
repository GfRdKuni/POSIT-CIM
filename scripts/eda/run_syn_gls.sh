#!/usr/bin/env bash
# ==============================================================================
# File    : run_syn_gls.sh
# Project : posit_cim_28nm
# Purpose : Post-synthesis SDF GLS runner for cim_top / ablations / cim_chip.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/run_syn_gls.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x run_syn_gls.sh
#
#   # Main cim_top, one corner:
#   ilaunch ./run_syn_gls.sh top tt0p9v25c
#
#   # Ablation TT:
#   ilaunch ./run_syn_gls.sh ablation tt0p9v25c
#
#   # Chip TT:
#   ilaunch ./run_syn_gls.sh chip tt0p9v25c
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. It assumes synthesis outputs are under ../syn/outputs_<tag>/.
#   3. MNIST_REAL_DATA is enabled by default. testdata/*.hex must exist.
# ==============================================================================

set -u
set -o pipefail

MODE=${1:-"top"}             # top | ablation | chip | custom
CORNER_ID=${2:-"tt0p9v25c"}

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
SYN_DIR=${SYN_DIR:-"${PROJ_ROOT}/syn"}

VCS_BIN=${VCS_BIN:-"vcs"}
VCS_COMMON_OPTS=${VCS_COMMON_OPTS:-"-full64 -sverilog +v2k -q -timescale=1ns/1ps"}

CLK_PERIOD_NS=${CLK_PERIOD_NS:-"2.8"}
ENABLE_MNIST=${ENABLE_MNIST:-1}

STD_CELL_V=${STD_CELL_V:-"/path/to/licensed_pdk/tsmcN28/TSMCHOME/digital/Front_End/verilog/tcbn28hpcplusbwp30p140_110a/tcbn28hpcplusbwp30p140.v"}
EXTRA_STD_CELL_V=${EXTRA_STD_CELL_V:-""}

if [ -z "${SYNOPSYS:-}" ]; then
    export SYNOPSYS="/tools/eda/synopsys/syn/T-2022.03-SP5-3"
fi
DW_SIM_DIR="${SYNOPSYS}/dw/sim_ver"

cd "${SIM_DIR}" || { echo "[FATAL] Cannot cd to ${SIM_DIR}" >&2; exit 1; }

if [[ "${ENABLE_MNIST}" == "1" ]]; then
    if ! ls "${SIM_DIR}/testdata"/*.hex >/dev/null 2>&1; then
        echo "[FATAL] ENABLE_MNIST=1 but no hex files found under ${SIM_DIR}/testdata" >&2
        exit 1
    fi
fi

build_defines() {
    local defs=()
    defs+=("+define+POST_SYN")
    defs+=("+define+CLK_PERIOD=${CLK_PERIOD_NS}")
    defs+=("+define+TB_FATAL_ON_FAIL")
    defs+=("+define+HAVE_REAL_RF_WRAPPER")
    if [[ "${ENABLE_MNIST}" == "1" ]]; then
        defs+=("+define+MNIST_REAL_DATA")
    fi
    printf "%s\n" "${defs[@]}"
}

std_cell_args() {
    local files=("${STD_CELL_V}")
    if [[ -n "${EXTRA_STD_CELL_V}" ]]; then
        # shellcheck disable=SC2206
        local extra=( ${EXTRA_STD_CELL_V} )
        files+=("${extra[@]}")
    fi

    local f
    for f in "${files[@]}"; do
        if [[ ! -f "${f}" ]]; then
            echo "[FATAL] Missing std-cell Verilog model: ${f}" >&2
            exit 1
        fi
        echo "-v"
        echo "${f}"
    done
}

run_one_gls() {
    local label="$1"
    local tb_file="$2"
    local tb_top="$3"
    local top_name="$4"
    local out_tag="$5"

    local out_dir="${SYN_DIR}/outputs_${out_tag}"
    local netlist="${out_dir}/${top_name}_${out_tag}.v"
    local sdf="${out_dir}/${top_name}_${out_tag}.sdf"

    if [[ ! -f "${netlist}" ]]; then
        echo "[SKIP] ${label}: missing netlist ${netlist}"
        return 2
    fi
    if [[ ! -f "${sdf}" ]]; then
        echo "[SKIP] ${label}: missing SDF ${sdf}"
        return 2
    fi
    if [[ ! -f "${tb_file}" ]]; then
        echo "[FAIL] ${label}: missing TB ${tb_file}" >&2
        return 1
    fi

    local work="${SIM_DIR}/sim_workspace_gls_${out_tag}"
    mkdir -p "${work}"

    local simv="${work}/simv_${out_tag}"
    local clog="${work}/vcs_compile_${out_tag}.log"
    local rlog="${work}/vcs_run_${out_tag}.log"
    local csrc="${work}/csrc_${out_tag}"
    local vcd="${work}/${tb_top}_${out_tag}.vcd"

    mapfile -t DEFINES < <(build_defines)
    mapfile -t STD_ARGS < <(std_cell_args)

    echo ""
    echo "======================================================================"
    echo " [GLS] ${label}"
    echo "======================================================================"
    echo "  OUT_TAG : ${out_tag}"
    echo "  TB      : ${tb_file}"
    echo "  TB_TOP  : ${tb_top}"
    echo "  NETLIST : ${netlist}"
    echo "  SDF     : ${sdf}"
    echo "  WORK    : ${work}"
    echo "======================================================================"

    "${VCS_BIN}" ${VCS_COMMON_OPTS} \
        +neg_tchk +negdelay \
        "${DEFINES[@]}" \
        "+define+SDF_PATH=\"${sdf}\"" \
        "+define+VCD_PATH=\"${vcd}\"" \
        "${tb_file}" "${netlist}" \
        "${STD_ARGS[@]}" \
        -y "${DW_SIM_DIR}" +libext+.v \
        -top "${tb_top}" \
        -Mdir="${csrc}" \
        -l "${clog}" \
        -o "${simv}"

    local rc=${PIPESTATUS[0]:-0}
    if [[ ${rc} -ne 0 ]]; then
        echo "[FAIL] ${label}: VCS compile failed, see ${clog}"
        return 1
    fi

    "${simv}" -l "${rlog}" -q
    rc=$?

    if [[ ${rc} -ne 0 ]]; then
        echo "[FAIL] ${label}: simulation exited with ${rc}, see ${rlog}"
        return 1
    fi

    grep -E "SDF Annotation|Doing SDF annotation|\[TB\] OVERALL:" "${rlog}" || true

    if grep -q "\[TB\] OVERALL: PASS" "${rlog}"; then
        echo "[OK] ${label}: GLS PASS"
        return 0
    else
        echo "[FAIL] ${label}: GLS did not report OVERALL PASS, see ${rlog}"
        return 1
    fi
}

fail=0
skip=0

case "${MODE}" in
    top)
        # outputs_<corner>/cim_top_<corner>.v
        run_one_gls "cim_top ${CORNER_ID}" "${SIM_DIR}/tb_cim_top.v" "tb_cim_top" "cim_top" "${CORNER_ID}" || rc=$?
        rc=${rc:-0}
        ;;
    ablation)
        rc=0
        for abl in mult mf dec; do
            top="cim_top_abl_${abl}"
            tag="abl_${abl}_${CORNER_ID}"
            run_one_gls "${top} ${CORNER_ID}" "${SIM_DIR}/tb_cim_top.v" "tb_cim_top" "${top}" "${tag}"
            one_rc=$?
            if [[ ${one_rc} -eq 2 ]]; then skip=$((skip+1)); elif [[ ${one_rc} -ne 0 ]]; then fail=$((fail+1)); fi
        done
        echo "[SUMMARY] ablation GLS: fail=${fail}, skip=${skip}"
        exit "${fail}"
        ;;
    chip)
        tag="chip_${CORNER_ID}"
        run_one_gls "cim_chip ${CORNER_ID}" "${SIM_DIR}/tb_cim_chip.v" "tb_cim_chip" "cim_chip" "${tag}" || rc=$?
        rc=${rc:-0}
        ;;
    custom)
        # User must pass/customize:
        #   TB_FILE=/path/tb.v TB_TOP=tb TOP_NAME=cim_top OUT_TAG=...
        : "${TB_FILE:?MODE=custom requires TB_FILE}"
        : "${TB_TOP:?MODE=custom requires TB_TOP}"
        : "${TOP_NAME:?MODE=custom requires TOP_NAME}"
        : "${OUT_TAG:?MODE=custom requires OUT_TAG}"
        run_one_gls "custom ${OUT_TAG}" "${TB_FILE}" "${TB_TOP}" "${TOP_NAME}" "${OUT_TAG}" || rc=$?
        rc=${rc:-0}
        ;;
    *)
        echo "[FATAL] Unknown MODE='${MODE}'. Use top|ablation|chip|custom." >&2
        exit 1
        ;;
esac

if [[ ${rc} -eq 2 ]]; then
    exit 0
fi
exit "${rc}"
