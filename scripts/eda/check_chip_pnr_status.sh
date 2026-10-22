#!/usr/bin/env bash
# ==============================================================================
# File    : check_chip_pnr_status.sh
# Purpose : Lightweight checker for chip Innovus progress and expected output
#           files. This does not modify anything.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/pnr/check_chip_pnr_status.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/pnr
#   ./check_chip_pnr_status.sh
#
# Env:
#   CHIP_TAG=chip_tt0p9v25c
#   CHIP_DESIGN=cim_chip
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
PNR_DIR=${PNR_DIR:-"${PROJ_ROOT}/pnr"}
CHIP_TAG=${CHIP_TAG:-"chip_tt0p9v25c"}
CHIP_DESIGN=${CHIP_DESIGN:-"cim_chip"}

RUN_DIR="${PNR_DIR}/runs_${CHIP_TAG}"
OUT_DIR="${RUN_DIR}/outputs"

echo "======================================================================"
echo " [CHIP PNR STATUS]"
echo "======================================================================"
echo " CHIP_TAG    : ${CHIP_TAG}"
echo " CHIP_DESIGN : ${CHIP_DESIGN}"
echo " RUN_DIR     : ${RUN_DIR}"
echo " OUT_DIR     : ${OUT_DIR}"
echo "======================================================================"

echo ""
echo "========== Process =========="
ps -fu "${USER}" | grep -Ei "innovus|encounter|${CHIP_TAG}|${CHIP_DESIGN}" | grep -v grep || true

echo ""
echo "========== Recent files =========="
find "${RUN_DIR}" -type f -printf "%TY-%Tm-%Td %TH:%TM %12s %p\n" 2>/dev/null | sort | tail -40 || true

echo ""
echo "========== Expected outputs =========="
for ext in enc v sdf def gds; do
    f="${OUT_DIR}/${CHIP_DESIGN}_${CHIP_TAG}_routed.${ext}"
    if [[ -e "${f}" ]]; then
        echo "[FOUND] ${f}"
    else
        echo "[MISS ] ${f}"
    fi
done

echo ""
echo "========== Logs =========="
find "${RUN_DIR}" "${PNR_DIR}" -maxdepth 3 -type f -name "*.log" 2>/dev/null \
    | grep -Ei "${CHIP_TAG}|chip|innovus" \
    | xargs -r ls -lh || true
