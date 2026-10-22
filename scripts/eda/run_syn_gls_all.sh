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
#   # Run everything that has synthesis outputs:
#   ilaunch ./run_syn_gls.sh all tt0p9v25c
#
#   # Run only one category:
#   ilaunch ./run_syn_gls.sh top tt0p9v25c
#   ilaunch ./run_syn_gls.sh ablation tt0p9v25c
#   ilaunch ./run_syn_gls.sh chip tt0p9v25c
#
#   # Run all discovered cim_top corner outputs:
#   ilaunch ./run_syn_gls.sh top_all
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. MNIST_REAL_DATA is enabled by default. testdata/*.hex must exist.
#   3. If synthesis output names differ, use MODE=custom through env variables:
#      TB_FILE=... TB_TOP=... TOP_NAME=... OUT_TAG=... ilaunch ./run_syn_gls.sh custom
# ==============================================================================

set -u
set -o pipefail

MODE=${1:-"all"}              # all | top | top_all | ablation | chip | custom
CORNER_ID=${2:-"tt0p9v25c"}

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
SYN_DIR=${SYN_DIR:-"${PROJ_ROOT}/syn"}

VCS_BIN=${VCS_BIN:-"vcs"}
VCS_COMMON_OPTS=${VCS_COMMON_OPTS:-"-full64 -sverilog +v2k -q -timescale=1ns/1ps"}

# This is for SDF GLS. Keep consistent with synthesis CLK_PERIOD.
CLK_PERIOD_NS=${CLK_PERIOD_NS:-"2.8"}

ENABLE_MNIST=${ENABLE_MNIST:-1}

# Standard-cell Verilog models for gate-level simulation.
# If synthesized netlists contain HVT/UHVT/LVT/ULVT cell module names that are
# not covered by the base model, add the corresponding models with EXTRA_STD_CELL_V.
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

    local rc=$?
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

accumulate() {
    local rc="$1"
    if [[ ${rc} -eq 0 ]]; then
        pass=$((pass + 1))
    elif [[ ${rc} -eq 2 ]]; then
        skip=$((skip + 1))
    else
        fail=$((fail + 1))
    fi
}

run_top_one() {
    local corner="$1"
    run_one_gls "cim_top ${corner}" "${SIM_DIR}/tb_cim_top.v" "tb_cim_top" "cim_top" "${corner}"
}

run_ablation_all() {
    local corner="$1"
    local abl top tag rc
    for abl in mult mf dec; do
        top="cim_top_abl_${abl}"
        tag="abl_${abl}_${corner}"
        run_one_gls "${top} ${corner}" "${SIM_DIR}/tb_cim_top.v" "tb_cim_top" "${top}" "${tag}"
        rc=$?
        accumulate "${rc}"
    done
}

run_chip_one() {
    local corner="$1"
    local tag="chip_${corner}"
    run_one_gls "cim_chip ${corner}" "${SIM_DIR}/tb_cim_chip.v" "tb_cim_chip" "cim_chip" "${tag}"
}

pass=0
fail=0
skip=0

case "${MODE}" in
    top)
        run_top_one "${CORNER_ID}"
        rc=$?
        accumulate "${rc}"
        ;;

    top_all)
        # Run every synthesis output directory that looks like outputs_<corner>
        # and contains cim_top_<corner>.v/.sdf. Excludes ablation/chip/hier tags.
        shopt -s nullglob
        found=0
        for d in "${SYN_DIR}"/outputs_*; do
            tag="$(basename "${d}")"
            tag="${tag#outputs_}"
            case "${tag}" in
                abl_*|chip_*|*_hier) continue ;;
            esac
            if [[ -f "${d}/cim_top_${tag}.v" && -f "${d}/cim_top_${tag}.sdf" ]]; then
                found=1
                run_top_one "${tag}"
                rc=$?
                accumulate "${rc}"
            fi
        done
        shopt -u nullglob
        if [[ ${found} -eq 0 ]]; then
            echo "[WARN] No cim_top synthesis outputs found under ${SYN_DIR}/outputs_*"
        fi
        ;;

    ablation)
        run_ablation_all "${CORNER_ID}"
        ;;

    chip)
        run_chip_one "${CORNER_ID}"
        rc=$?
        accumulate "${rc}"
        ;;

    all)
        run_top_one "${CORNER_ID}"
        rc=$?
        accumulate "${rc}"

        run_ablation_all "${CORNER_ID}"

        run_chip_one "${CORNER_ID}"
        rc=$?
        accumulate "${rc}"
        ;;

    custom)
        : "${TB_FILE:?MODE=custom requires TB_FILE}"
        : "${TB_TOP:?MODE=custom requires TB_TOP}"
        : "${TOP_NAME:?MODE=custom requires TOP_NAME}"
        : "${OUT_TAG:?MODE=custom requires OUT_TAG}"
        run_one_gls "custom ${OUT_TAG}" "${TB_FILE}" "${TB_TOP}" "${TOP_NAME}" "${OUT_TAG}"
        rc=$?
        accumulate "${rc}"
        ;;

    *)
        echo "[FATAL] Unknown MODE='${MODE}'. Use all|top|top_all|ablation|chip|custom." >&2
        exit 1
        ;;
esac

echo ""
echo "======================================================================"
echo " GLS SUMMARY"
echo "======================================================================"
echo " PASS : ${pass}"
echo " FAIL : ${fail}"
echo " SKIP : ${skip}"
echo "======================================================================"

if [[ ${fail} -ne 0 ]]; then
    exit 1
fi
exit 0
