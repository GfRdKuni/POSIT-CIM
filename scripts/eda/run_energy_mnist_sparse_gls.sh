#!/usr/bin/env bash
# ==============================================================================
# File    : run_energy_mnist_sparse_gls.sh
# Project : posit_cim_28nm
# Purpose : One-command post-route GLS runner for MNIST-based sparsity/energy TB.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/run_energy_mnist_sparse_gls.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x run_energy_mnist_sparse_gls.sh
#
#   # Smoke: run abl_mf, p16_l1, A sparsity=50%, W sparsity=0%, seed=1
#   ilaunch ./run_energy_mnist_sparse_gls.sh mf p16_l1 50 0 1
#
#   # Run top_hier
#   ilaunch ./run_energy_mnist_sparse_gls.sh top_hier p16_l1 50 0 1
#
#   # Run abl_mult
#   ilaunch ./run_energy_mnist_sparse_gls.sh mult p16_l1 50 0 1
#
#   # Run abl_dec after it is fixed
#   ilaunch ./run_energy_mnist_sparse_gls.sh dec p16_l1 50 0 1
#
# Environment overrides:
#   PROJ_ROOT=/path/to/projects/posit_cim_28nm
#   CLK_PERIOD_NS=1.08
#   MAX_OPS=1          # recommended for first smoke
#   MAX_OPS=8          # full 8 MNIST ops
#   CORNER_ID=tt0p9v25c
#   TOP_HIER_TAG=tt_0p90v_0p90v_25c_hier
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. It does NOT require filelist.f.
#   3. It directly lists std-cell Verilog models, routed netlist, and energy TB.
#   4. It filters out *_pwr.v / *_cdl.v / *_lvs.v models for non-PG GLS.
#   5. It generates:
#        sim/energy_runs/${TAG}/${RUN_NAME}/simv
#        sim/energy_runs/${TAG}/${RUN_NAME}/compile.log
#        sim/energy_runs/${TAG}/${RUN_NAME}/sim.log
#        sim/energy_runs/${TAG}/${RUN_NAME}/wave.vcd
#        sim/energy_runs/${TAG}/${RUN_NAME}/perf.csv
# ==============================================================================

set -e
set -u
set -o pipefail

MODE=${1:-"mf"}                 # top_hier | top | mf | mult | dec | custom
WORKLOAD=${2:-"p16_l1"}         # p16_l1 | p16_l2 | p8_l1
A_SPARSITY_PCT=${3:-"50"}       # 0 / 25 / 50 / 75 / 90
W_SPARSITY_PCT=${4:-"0"}        # 0 / 25 / 50 / 75 / 90
MASK_SEED=${5:-"1"}

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
PNR_DIR=${PNR_DIR:-"${PROJ_ROOT}/pnr"}

VCS_BIN=${VCS_BIN:-"vcs"}
VCS_COMMON_OPTS=${VCS_COMMON_OPTS:-"-full64 -sverilog +v2k -q -timescale=1ns/1ps -debug_access+all"}
CLK_PERIOD_NS=${CLK_PERIOD_NS:-"1.08"}
MAX_OPS=${MAX_OPS:-"1"}

CORNER_ID=${CORNER_ID:-"tt0p9v25c"}
TOP_HIER_TAG=${TOP_HIER_TAG:-"tt_0p90v_0p90v_25c_hier"}

STD_VERILOG_ROOT=${STD_VERILOG_ROOT:-"/path/to/licensed_pdk/tsmcN28/TSMCHOME/digital/Front_End/verilog"}

TB_FILE=${TB_FILE:-"${SIM_DIR}/energy_tb/tb_cim_top_mnist_sparse.v"}
TB_TOP=${TB_TOP:-"tb_cim_top_mnist_sparse"}

cd "${SIM_DIR}" || { echo "[FATAL] Cannot cd to ${SIM_DIR}" >&2; exit 1; }

if [[ ! -f "${TB_FILE}" ]]; then
    echo "[FATAL] Missing energy TB: ${TB_FILE}" >&2
    echo "        Please put tb_cim_top_mnist_sparse.v under sim/energy_tb/ first." >&2
    exit 1
fi

if ! ls "${SIM_DIR}/testdata"/*.hex >/dev/null 2>&1; then
    echo "[FATAL] No MNIST hex files found under ${SIM_DIR}/testdata" >&2
    echo "        This TB expects to run from sim/ and read testdata/*.hex." >&2
    exit 1
fi

case "${MODE}" in
    top|top_hier)
        KEY="top_hier"
        TAG="${TOP_HIER_TAG}"
        DESIGN_NAME="cim_top"
        NETLIST_TOP="cim_top"
        ;;
    mf)
        KEY="abl_mf"
        TAG="abl_mf_${CORNER_ID}"
        DESIGN_NAME="cim_top_abl_mf"
        NETLIST_TOP="cim_top_abl_mf"
        ;;
    mult)
        KEY="abl_mult"
        TAG="abl_mult_${CORNER_ID}"
        DESIGN_NAME="cim_top_abl_mult"
        NETLIST_TOP="cim_top_abl_mult"
        ;;
    dec)
        KEY="abl_dec"
        TAG="abl_dec_${CORNER_ID}"
        DESIGN_NAME="cim_top_abl_dec"
        NETLIST_TOP="cim_top_abl_dec"
        ;;
    custom)
        : "${KEY:?MODE=custom requires KEY}"
        : "${TAG:?MODE=custom requires TAG}"
        : "${DESIGN_NAME:?MODE=custom requires DESIGN_NAME}"
        : "${NETLIST_TOP:?MODE=custom requires NETLIST_TOP}"
        ;;
    *)
        echo "[FATAL] Unknown MODE='${MODE}'. Use top_hier|mf|mult|dec|custom." >&2
        exit 1
        ;;
esac

OUT_DIR="${PNR_DIR}/runs_${TAG}/outputs"
NETLIST="${OUT_DIR}/${NETLIST_TOP}_${TAG}_routed.v"
SDF="${OUT_DIR}/${NETLIST_TOP}_${TAG}_routed.sdf"

if [[ ! -f "${NETLIST}" ]]; then
    echo "[FATAL] Missing routed netlist: ${NETLIST}" >&2
    exit 1
fi

if [[ ! -f "${SDF}" ]]; then
    echo "[FATAL] Missing routed SDF: ${SDF}" >&2
    exit 1
fi

RUN_NAME="${WORKLOAD}_a$(printf "%03d" "${A_SPARSITY_PCT}")_w$(printf "%03d" "${W_SPARSITY_PCT}")_seed${MASK_SEED}"
WORK_DIR="${SIM_DIR}/energy_runs/${TAG}/${RUN_NAME}"
mkdir -p "${WORK_DIR}"

SIMV="${WORK_DIR}/simv"
CSRC="${WORK_DIR}/csrc"
CLOG="${WORK_DIR}/compile.log"
RLOG="${WORK_DIR}/sim.log"
VCD="${WORK_DIR}/wave.vcd"
PERF="${WORK_DIR}/perf.csv"

std_cell_args() {
    local files=()

    if [[ -n "${STD_CELL_V_LIST:-}" ]]; then
        # User override, space-separated.
        # shellcheck disable=SC2206
        files=( ${STD_CELL_V_LIST} )
    else
        while IFS= read -r f; do
            files+=("${f}")
        done < <(
            find "${STD_VERILOG_ROOT}" -maxdepth 3 -type f \
                -path "*tcbn28hpcplusbwp30p140*" \
                -name "tcbn28hpcplusbwp30p140*.v" \
                ! -name "*_pwr.v" \
                ! -name "*_cdl.v" \
                ! -name "*_lvs.v" 2>/dev/null | sort -u
        )
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "[FATAL] No std-cell Verilog models found under ${STD_VERILOG_ROOT}" >&2
        echo "        You may set STD_CELL_V_LIST manually." >&2
        exit 1
    fi

    local f
    for f in "${files[@]}"; do
        case "$(basename "${f}")" in
            *_pwr.v|*_cdl.v|*_lvs.v)
                echo "[INFO] Skip power/LVS std-cell model for GLS: ${f}" >&2
                continue
                ;;
        esac
        if [[ ! -f "${f}" ]]; then
            echo "[FATAL] Missing std-cell Verilog model: ${f}" >&2
            exit 1
        fi
        echo "-v"
        echo "${f}"
    done
}

dw_args() {
    local candidates=()

    if [[ -n "${SYNOPSYS:-}" ]]; then
        candidates+=("${SYNOPSYS}/dw/sim_ver")
    fi
    candidates+=("/path/to/eda_tools/synopsys/syn-2019.03/dw/sim_ver")
    candidates+=("/path/to/eda_tools/synopsys/syn-2019.03/libraries/syn")
    candidates+=("/tools/eda/synopsys/syn/T-2022.03-SP5-3/dw/sim_ver")

    local d
    for d in "${candidates[@]}"; do
        if [[ -d "${d}" ]]; then
            echo "-y"
            echo "${d}"
            echo "+libext+.v"
            return 0
        fi
    done

    echo "[WARN] No DesignWare simulation directory found; continuing without -y DW dir." >&2
    return 0
}

mapfile -t STD_ARGS < <(std_cell_args)
mapfile -t DW_ARGS  < <(dw_args)

echo ""
echo "======================================================================"
echo " [MNIST SPARSE ENERGY GLS]"
echo "======================================================================"
echo "  MODE            : ${MODE}"
echo "  KEY             : ${KEY}"
echo "  TAG             : ${TAG}"
echo "  DESIGN_NAME     : ${DESIGN_NAME}"
echo "  NETLIST_TOP     : ${NETLIST_TOP}"
echo "  WORKLOAD        : ${WORKLOAD}"
echo "  A_SPARSITY_PCT  : ${A_SPARSITY_PCT}"
echo "  W_SPARSITY_PCT  : ${W_SPARSITY_PCT}"
echo "  MASK_SEED       : ${MASK_SEED}"
echo "  MAX_OPS         : ${MAX_OPS}"
echo "  CLK_PERIOD_NS   : ${CLK_PERIOD_NS}"
echo "  NETLIST         : ${NETLIST}"
echo "  SDF             : ${SDF}"
echo "  TB_FILE         : ${TB_FILE}"
echo "  WORK_DIR        : ${WORK_DIR}"
echo "  VCD             : ${VCD}"
echo "  PERF            : ${PERF}"
echo "======================================================================"

"${VCS_BIN}" ${VCS_COMMON_OPTS} \
    +neg_tchk +negdelay +no_notifier \
    "${STD_ARGS[@]}" \
    "${DW_ARGS[@]}" \
    "${NETLIST}" \
    "${TB_FILE}" \
    -top "${TB_TOP}" \
    -Mdir="${CSRC}" \
    -o "${SIMV}" \
    -l "${CLOG}" \
    +lint=TFIPC-L \
    +define+POST_SYN \
    +define+POST_ROUTE \
    +define+HAVE_REAL_RF_WRAPPER \
    +define+ENERGY_COMPUTE_DUMP \
    +define+TB_FATAL_ON_FAIL \
    +define+DUT_TOP=${DESIGN_NAME} \
    +define+DUT_NAME=\"${KEY}\" \
    +define+CLK_PERIOD=${CLK_PERIOD_NS} \
    +define+SDF_PATH=\"${SDF}\" \
    +define+VCD_PATH=\"${VCD}\" \
    +define+PERF_CSV_PATH=\"${PERF}\"

rc=$?
if [[ ${rc} -ne 0 ]]; then
    echo "[FAIL] VCS compile failed, see ${CLOG}" >&2
    exit 1
fi

"${SIMV}" \
    +WORKLOAD=${WORKLOAD} \
    +A_SPARSITY_PCT=${A_SPARSITY_PCT} \
    +W_SPARSITY_PCT=${W_SPARSITY_PCT} \
    +MASK_SEED=${MASK_SEED} \
    +MAX_OPS=${MAX_OPS} \
    -l "${RLOG}" \
    -q

rc=$?
if [[ ${rc} -ne 0 ]]; then
    echo "[FAIL] Simulation exited with ${rc}, see ${RLOG}" >&2
    exit 1
fi

echo ""
echo "======================================================================"
echo " [LOG SUMMARY]"
echo "======================================================================"
grep -E "SDF Annotation|Doing SDF annotation|\[WORKLOAD\]|\[PERF\]|\[RESULT\]|\[TB\] OVERALL|FAIL|ERROR|timeout" "${RLOG}" || true
echo "======================================================================"

if [[ ! -f "${PERF}" ]]; then
    echo "[FAIL] Missing perf CSV: ${PERF}" >&2
    exit 1
fi

if [[ ! -f "${VCD}" ]]; then
    echo "[FAIL] Missing VCD: ${VCD}" >&2
    exit 1
fi

if grep -q "\[TB\] OVERALL: PASS" "${RLOG}"; then
    echo "[OK] MNIST sparse GLS PASS"
    echo "[OK] PERF: ${PERF}"
    echo "[OK] VCD : ${VCD}"
    exit 0
else
    echo "[FAIL] GLS did not report OVERALL PASS, see ${RLOG}" >&2
    exit 1
fi
