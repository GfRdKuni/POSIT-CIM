#!/usr/bin/env bash
# ==============================================================================
# File    : run_energy_primepower_all_cleanfreq_swapaw.sh
# Purpose : Run PrimePower for all SWAP-A/W workload SAIFs using per-design
#           clean period/session from clean_periods.tsv.
#
# Input:
#   sim/energy_runs_swapaw/${TAG}/${WORKLOAD}/activity.saif
#
# Output:
#   pt/power_workloads_swapaw/${TAG}/${WORKLOAD}/power_total.rpt
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
PT_DIR=${PT_DIR:-"${PROJ_ROOT}/pt"}
ENERGY_RUNS_DIR=${ENERGY_RUNS_DIR:-"${SIM_DIR}/energy_runs_swapaw"}
POWER_WORKLOADS_DIR=${POWER_WORKLOADS_DIR:-"${PT_DIR}/power_workloads_swapaw"}
PERIOD_CFG=${PERIOD_CFG:-"${SIM_DIR}/energy_tb/configs/clean_periods.tsv"}
TAGS=${TAGS:-""}
FORCE=${FORCE:-0}

cd "${SIM_DIR}" || { echo "[FATAL] Cannot cd to ${SIM_DIR}" >&2; exit 1; }

if [[ ! -f "${PERIOD_CFG}" ]]; then
    echo "[FATAL] Missing period config: ${PERIOD_CFG}" >&2
    exit 1
fi

if [[ ! -x "${SIM_DIR}/run_energy_primepower_one_swapaw.sh" ]]; then
    echo "[FATAL] Missing executable ${SIM_DIR}/run_energy_primepower_one_swapaw.sh" >&2
    exit 1
fi

period_for_tag() {
    local tag="$1"
    awk -F'\t' -v t="${tag}" '
        /^[[:space:]]*#/ { next }
        NF < 4 { next }
        $2 == t { print $4; found=1; exit }
        END { if (!found) exit 2 }
    ' "${PERIOD_CFG}"
}

echo "======================================================================"
echo " [SWAP-AW PRIMEPOWER ENERGY ALL @ CLEAN PER-DESIGN FREQUENCY]"
echo "======================================================================"
echo "  ENERGY_RUNS_DIR     : ${ENERGY_RUNS_DIR}"
echo "  POWER_WORKLOADS_DIR : ${POWER_WORKLOADS_DIR}"
echo "  PERIOD_CFG          : ${PERIOD_CFG}"
echo "  TAGS                : ${TAGS:-<all>}"
echo "  FORCE               : ${FORCE}"
echo "======================================================================"

pass=0
skip=0
fail=0

run_one_saif() {
    local saif="$1"
    local tag workload rpt period

    tag=$(echo "${saif}" | awk -F'/' '{print $(NF-2)}')
    workload=$(echo "${saif}" | awk -F'/' '{print $(NF-1)}')
    rpt="${POWER_WORKLOADS_DIR}/${tag}/${workload}/power_total.rpt"

    period=$(period_for_tag "${tag}") || {
        echo "[FAIL] No clean period for tag=${tag} in ${PERIOD_CFG}" >&2
        fail=$((fail + 1))
        return 0
    }

    if [[ -f "${rpt}" && "${FORCE}" != "1" ]]; then
        echo "[SKIP] Power exists: ${rpt}"
        skip=$((skip + 1))
        return 0
    fi

    echo ""
    echo "----------------------------------------------------------------------"
    echo "[SWAP-AW POWER] TAG=${tag} WORKLOAD=${workload} PERIOD=${period}ns"
    echo "----------------------------------------------------------------------"

    if TAG="${tag}" WORKLOAD="${workload}" POWER_PERIOD="${period}" \
        ENERGY_RUNS_DIR="${ENERGY_RUNS_DIR}" \
        POWER_WORKLOADS_DIR="${POWER_WORKLOADS_DIR}" \
        "${SIM_DIR}/run_energy_primepower_one_swapaw.sh"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
}

if [[ -n "${TAGS}" ]]; then
    for tag in ${TAGS}; do
        while IFS= read -r saif; do
            run_one_saif "${saif}"
        done < <(find "${ENERGY_RUNS_DIR}/${tag}" -mindepth 2 -maxdepth 2 -name activity.saif 2>/dev/null | sort)
    done
else
    while IFS= read -r saif; do
        run_one_saif "${saif}"
    done < <(find "${ENERGY_RUNS_DIR}" -mindepth 3 -maxdepth 3 -name activity.saif | sort)
fi

echo ""
echo "======================================================================"
echo " [SWAP-AW PRIMEPOWER ALL CLEANFREQ SUMMARY]"
echo "======================================================================"
echo "  PASS : ${pass}"
echo "  SKIP : ${skip}"
echo "  FAIL : ${fail}"
echo "======================================================================"

if [[ ${fail} -ne 0 ]]; then
    exit 1
fi
exit 0
