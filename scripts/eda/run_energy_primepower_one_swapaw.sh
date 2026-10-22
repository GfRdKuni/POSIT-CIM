#!/usr/bin/env bash
# ==============================================================================
# File    : run_energy_primepower_one_swapaw.sh
# Purpose : Run PrimePower for one SWAP-A/W MNIST sparse energy workload SAIF.
#
# Input:
#   sim/energy_runs_swapaw/${TAG}/${WORKLOAD}/activity.saif
#
# Output:
#   pt/power_workloads_swapaw/${TAG}/${WORKLOAD}/power_total.rpt
#
# It restores the original PT/PrimePower session from:
#   pt/runs_${TAG}_power/
# so no new PPA / PnR / PT session is required.
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
TAG=${TAG:?Please set TAG, e.g. abl_mf_tt0p9v25c}
WORKLOAD=${WORKLOAD:?Please set WORKLOAD, e.g. p16_l1_a050_w000_seed1}
POWER_PERIOD=${POWER_PERIOD:-"1.08"}
SAIF_INSTANCE=${SAIF_INSTANCE:-"tb_cim_top_mnist_sparse/dut"}

SIM_DIR="${PROJ_ROOT}/sim"
PT_DIR="${PROJ_ROOT}/pt"
ENERGY_RUNS_DIR=${ENERGY_RUNS_DIR:-"${SIM_DIR}/energy_runs_swapaw"}
POWER_WORKLOADS_DIR=${POWER_WORKLOADS_DIR:-"${PT_DIR}/power_workloads_swapaw"}

period_tag="${POWER_PERIOD/./p}"

design_name_from_tag() {
    case "$1" in
        abl_mf_tt0p9v25c) echo "cim_top_abl_mf" ;;
        abl_mult_tt0p9v25c) echo "cim_top_abl_mult" ;;
        abl_dec_tt0p9v25c) echo "cim_top_abl_dec" ;;
        tt_0p90v_0p90v_25c_hier) echo "cim_top" ;;
        chip_tt0p9v25c) echo "cim_chip" ;;
        *)
            echo ""
            ;;
    esac
}

DESIGN_NAME=${DESIGN_NAME:-"$(design_name_from_tag "${TAG}")"}
if [[ -z "${DESIGN_NAME}" ]]; then
    echo "[FATAL] Cannot infer DESIGN_NAME from TAG=${TAG}. Set DESIGN_NAME manually." >&2
    exit 1
fi

SAIF="${ENERGY_RUNS_DIR}/${TAG}/${WORKLOAD}/activity.saif"
OUT_DIR="${POWER_WORKLOADS_DIR}/${TAG}/${WORKLOAD}"
mkdir -p "${OUT_DIR}"

if [[ ! -f "${SAIF}" ]]; then
    echo "[FATAL] Missing SAIF: ${SAIF}" >&2
    exit 1
fi

find_session_dir() {
    local base="${PT_DIR}/runs_${TAG}_power"
    local cands=()

    cands+=("${base}/pt_session_${TAG}_${period_tag}ns")
    cands+=("${base}/pt_session_${TAG}_${period_tag}")
    cands+=("${base}/pt_session_${TAG}")
    cands+=("${base}/pt_session_${TAG}_1p08ns")
    cands+=("${base}/pt_session_${TAG}_1p08")

    local c
    for c in "${cands[@]}"; do
        if [[ -d "${c}" ]]; then
            echo "${c}"
            return 0
        fi
    done

    if [[ -d "${base}" ]]; then
        local found
        found=$(find "${base}" -maxdepth 1 -type d -name "pt_session*" | sort | tail -1 || true)
        if [[ -n "${found}" && -d "${found}" ]]; then
            echo "${found}"
            return 0
        fi
    fi

    return 1
}

SESSION_DIR=$(find_session_dir || true)
if [[ -z "${SESSION_DIR:-}" ]]; then
    echo "[FATAL] Cannot find PT/PrimePower session under ${PT_DIR}/runs_${TAG}_power" >&2
    echo "        Expected something like pt_session_${TAG}_${period_tag}ns or pt_session_${TAG}" >&2
    exit 1
fi

cd "${OUT_DIR}"

cat > run_power.tcl <<EOF
set DESIGN_NAME ${DESIGN_NAME}
set SESSION_DIR ${SESSION_DIR}
set SAIF ${SAIF}
set SAIF_INSTANCE ${SAIF_INSTANCE}

puts "========== Restore session =========="
puts "SESSION_DIR = \$SESSION_DIR"
restore_session \$SESSION_DIR
current_design \$DESIGN_NAME

# restore_session may restore old Tcl variables, including REPORT_DIR.
# Therefore REPORT_DIR must be reset after restore_session.
set REPORT_DIR [pwd]
file mkdir \$REPORT_DIR

puts "========== Read SAIF =========="
puts "SAIF = \$SAIF"
puts "SAIF_INSTANCE = \$SAIF_INSTANCE"

read_saif \$SAIF -strip_path \$SAIF_INSTANCE \\
  -report_inconsistent_annotation \$REPORT_DIR/saif_inconsistent.rpt

report_switching_activity -list_not_annotated > \$REPORT_DIR/switching_not_annotated.rpt
report_switching_activity > \$REPORT_DIR/switching_summary.rpt

puts "========== Power =========="
check_power > \$REPORT_DIR/check_power.rpt
update_power

report_power > \$REPORT_DIR/power_total.rpt
report_power -hierarchy > \$REPORT_DIR/power_hier.rpt
report_power -verbose > \$REPORT_DIR/power_verbose.rpt

quit
EOF

echo ""
echo "======================================================================"
echo " [SWAP-AW PRIMEPOWER ENERGY ONE]"
echo "======================================================================"
echo "  TAG                 : ${TAG}"
echo "  DESIGN_NAME         : ${DESIGN_NAME}"
echo "  WORKLOAD            : ${WORKLOAD}"
echo "  POWER_PERIOD        : ${POWER_PERIOD}"
echo "  SESSION_DIR         : ${SESSION_DIR}"
echo "  SAIF                : ${SAIF}"
echo "  SAIF_INSTANCE       : ${SAIF_INSTANCE}"
echo "  OUT_DIR             : ${OUT_DIR}"
echo "  POWER_WORKLOADS_DIR : ${POWER_WORKLOADS_DIR}"
echo "======================================================================"

primepower -f run_power.tcl < /dev/null | tee power.log

grep -Ei "annotated nets|fully annotated|Running averaged power|PWR-|ERROR|FATAL" power.log | tail -120 || true

if [[ ! -f power_total.rpt ]]; then
    echo "[FAIL] Missing power_total.rpt under ${OUT_DIR}" >&2
    exit 1
fi

echo "[OK] Power report: ${OUT_DIR}/power_total.rpt"
