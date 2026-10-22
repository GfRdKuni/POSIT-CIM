#!/usr/bin/env bash
# ==============================================================================
# File    : run_energy_primepower_all.sh
# Purpose : Run PrimePower for all MNIST sparse energy workload SAIFs.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/run_energy_primepower_all.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x run_energy_primepower_all.sh
#
#   TAGS="abl_mf_tt0p9v25c abl_mult_tt0p9v25c tt_0p90v_0p90v_25c_hier" \
#   POWER_PERIOD=1.08 \
#   ilaunch ./run_energy_primepower_all.sh
#
# Notes:
#   - This script does NOT call ilaunch internally.
#   - It iterates over sim/energy_runs/${TAG}/*/activity.saif.
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
ENERGY_RUNS_DIR=${ENERGY_RUNS_DIR:-"${SIM_DIR}/energy_runs"}
TAGS=${TAGS:-""}
POWER_PERIOD=${POWER_PERIOD:-"1.08"}
FORCE=${FORCE:-0}

cd "${SIM_DIR}" || { echo "[FATAL] Cannot cd to ${SIM_DIR}" >&2; exit 1; }

echo "======================================================================"
echo " [PRIMEPOWER ENERGY ALL]"
echo "======================================================================"
echo "  ENERGY_RUNS_DIR : ${ENERGY_RUNS_DIR}"
echo "  TAGS            : ${TAGS:-<all>}"
echo "  POWER_PERIOD    : ${POWER_PERIOD}"
echo "  FORCE           : ${FORCE}"
echo "======================================================================"

pass=0
skip=0
fail=0

run_one_saif() {
    local saif="$1"
    local tag workload rpt
    tag=$(echo "${saif}" | awk -F'/' '{print $(NF-2)}')
    workload=$(echo "${saif}" | awk -F'/' '{print $(NF-1)}')
    rpt="${PROJ_ROOT}/pt/power_workloads/${tag}/${workload}/power_total.rpt"

    if [[ -f "${rpt}" && "${FORCE}" != "1" ]]; then
        echo "[SKIP] Power exists: ${rpt}"
        skip=$((skip + 1))
        return 0
    fi

    echo ""
    echo "----------------------------------------------------------------------"
    echo "[POWER] TAG=${tag} WORKLOAD=${workload}"
    echo "----------------------------------------------------------------------"

    if TAG="${tag}" WORKLOAD="${workload}" POWER_PERIOD="${POWER_PERIOD}" \
        "${SIM_DIR}/run_energy_primepower_one.sh"; then
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
echo " [PRIMEPOWER ALL SUMMARY]"
echo "======================================================================"
echo "  PASS : ${pass}"
echo "  SKIP : ${skip}"
echo "  FAIL : ${fail}"
echo "======================================================================"

if [[ ${fail} -ne 0 ]]; then
    exit 1
fi
exit 0
