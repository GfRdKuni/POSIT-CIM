#!/usr/bin/env bash
# ==============================================================================
# File    : run_hold_eco_all.sh
# Purpose : Run hold ECO for multiple single-core designs.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/pnr/run_hold_eco_all.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/pnr
#   chmod +x run_hold_eco_all.sh
#
#   # Smoke on mf only
#   DESIGNS="mf" ilaunch ./run_hold_eco_all.sh
#
#   # All currently available single-core designs
#   DESIGNS="top_hier mf mult" ilaunch ./run_hold_eco_all.sh
#
#   # Add dec after it is fixed
#   DESIGNS="top_hier mf mult dec" ilaunch ./run_hold_eco_all.sh
#
# Env:
#   HOLD_ITER=2
#   SETUP_CHECK=1
#   DO_GDS=1
# ==============================================================================

set -e
set -u
set -o pipefail

DESIGNS=${DESIGNS:-"top_hier mf mult"}
HOLD_ITER=${HOLD_ITER:-2}
SETUP_CHECK=${SETUP_CHECK:-1}
DO_GDS=${DO_GDS:-1}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ONE="${SCRIPT_DIR}/run_hold_eco_one.sh"

if [[ ! -x "${ONE}" ]]; then
    echo "[FATAL] Missing executable: ${ONE}" >&2
    exit 1
fi

echo "======================================================================"
echo " [RUN HOLD ECO ALL]"
echo "======================================================================"
echo " DESIGNS     : ${DESIGNS}"
echo " HOLD_ITER   : ${HOLD_ITER}"
echo " SETUP_CHECK : ${SETUP_CHECK}"
echo " DO_GDS      : ${DO_GDS}"
echo "======================================================================"

pass=0
fail=0

for d in ${DESIGNS}; do
    echo ""
    echo "----------------------------------------------------------------------"
    echo "[HOLD ECO] ${d}"
    echo "----------------------------------------------------------------------"

    if HOLD_ITER="${HOLD_ITER}" SETUP_CHECK="${SETUP_CHECK}" DO_GDS="${DO_GDS}" \
        "${ONE}" "${d}"; then
        pass=$((pass + 1))
    else
        echo "[FAIL] hold ECO failed for ${d}" >&2
        fail=$((fail + 1))
    fi
done

echo ""
echo "======================================================================"
echo " [HOLD ECO ALL SUMMARY]"
echo "======================================================================"
echo " PASS : ${pass}"
echo " FAIL : ${fail}"
echo "======================================================================"

if [[ ${fail} -ne 0 ]]; then
    exit 1
fi

exit 0
