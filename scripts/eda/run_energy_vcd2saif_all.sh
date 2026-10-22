#!/usr/bin/env bash
# ==============================================================================
# File    : run_energy_vcd2saif_all.sh
# Purpose : Convert all MNIST sparse energy GLS VCDs to SAIF.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/run_energy_vcd2saif_all.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x run_energy_vcd2saif_all.sh
#   ilaunch ./run_energy_vcd2saif_all.sh
#
# Optional filters:
#   TAGS="abl_mf_tt0p9v25c abl_mult_tt0p9v25c" ilaunch ./run_energy_vcd2saif_all.sh
#   FORCE=1 ilaunch ./run_energy_vcd2saif_all.sh
#
# Notes:
#   - This script does NOT call ilaunch internally.
#   - Instance path is for tb_cim_top_mnist_sparse.v:
#       tb_cim_top_mnist_sparse/dut
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
ENERGY_RUNS_DIR=${ENERGY_RUNS_DIR:-"${SIM_DIR}/energy_runs"}
SAIF_INSTANCE=${SAIF_INSTANCE:-"tb_cim_top_mnist_sparse/dut"}
FORCE=${FORCE:-0}
TAGS=${TAGS:-""}

cd "${SIM_DIR}" || { echo "[FATAL] Cannot cd to ${SIM_DIR}" >&2; exit 1; }

if [[ ! -d "${ENERGY_RUNS_DIR}" ]]; then
    echo "[FATAL] Missing energy_runs dir: ${ENERGY_RUNS_DIR}" >&2
    exit 1
fi

echo "======================================================================"
echo " [VCD -> SAIF ALL]"
echo "======================================================================"
echo "  ENERGY_RUNS_DIR : ${ENERGY_RUNS_DIR}"
echo "  SAIF_INSTANCE   : ${SAIF_INSTANCE}"
echo "  FORCE           : ${FORCE}"
echo "  TAGS            : ${TAGS:-<all>}"
echo "======================================================================"

pass=0
skip=0
fail=0

run_one() {
    local vcd="$1"
    local dir
    dir=$(dirname "${vcd}")
    local saif="${dir}/activity.saif"
    local log="${dir}/vcd2saif.log"

    if [[ -f "${saif}" && "${FORCE}" != "1" ]]; then
        echo "[SKIP] SAIF exists: ${saif}"
        skip=$((skip + 1))
        return 0
    fi

    echo ""
    echo "----------------------------------------------------------------------"
    echo "[VCD2SAIF] ${vcd}"
    echo "----------------------------------------------------------------------"

    if vcd2saif -input "${vcd}" -output "${saif}" -instance "${SAIF_INSTANCE}" | tee "${log}"; then
        if [[ -s "${saif}" ]]; then
            echo "[OK] ${saif}"
            pass=$((pass + 1))
        else
            echo "[FAIL] SAIF not created or empty: ${saif}" >&2
            fail=$((fail + 1))
        fi
    else
        echo "[FAIL] vcd2saif failed: ${vcd}" >&2
        fail=$((fail + 1))
    fi
}

if [[ -n "${TAGS}" ]]; then
    for tag in ${TAGS}; do
        if [[ ! -d "${ENERGY_RUNS_DIR}/${tag}" ]]; then
            echo "[WARN] Missing tag dir: ${ENERGY_RUNS_DIR}/${tag}" >&2
            continue
        fi
        while IFS= read -r vcd; do
            run_one "${vcd}"
        done < <(find "${ENERGY_RUNS_DIR}/${tag}" -mindepth 2 -maxdepth 2 -name wave.vcd | sort)
    done
else
    while IFS= read -r vcd; do
        run_one "${vcd}"
    done < <(find "${ENERGY_RUNS_DIR}" -mindepth 3 -maxdepth 3 -name wave.vcd | sort)
fi

echo ""
echo "======================================================================"
echo " [VCD2SAIF SUMMARY]"
echo "======================================================================"
echo "  PASS : ${pass}"
echo "  SKIP : ${skip}"
echo "  FAIL : ${fail}"
echo "======================================================================"

if [[ ${fail} -ne 0 ]]; then
    exit 1
fi
exit 0
