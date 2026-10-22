#!/usr/bin/env bash
# ==============================================================================
# File    : run_chip_syn.sh
# Project : posit_cim_28nm
# Purpose : Single-corner mixed-Vt synthesis driver for cim_chip.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/syn/run_chip_syn.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/syn
#   chmod +x run_chip_syn.sh
#   ilaunch ./run_chip_syn.sh
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. Default corner is TT nominal: tt0p9v25c.
# ==============================================================================

set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SYN_DIR=${SYN_DIR:-"${PROJ_ROOT}/syn"}
DC_BIN=${DC_BIN:-"dc_shell"}

CORNER_ID=${CORNER_ID:-"tt0p9v25c"}
OUT_TAG=${OUT_TAG:-"chip_${CORNER_ID}"}
CLK_PERIOD=${CLK_PERIOD:-"2.8"}

cd "${SYN_DIR}" || { echo "[FATAL] Cannot cd to ${SYN_DIR}" >&2; exit 1; }

TCL_SCRIPT="${SYN_DIR}/syn_chip.tcl"
LOG_FILE="syn_${OUT_TAG}.log"

if [[ ! -f "${TCL_SCRIPT}" ]]; then
    echo "[FATAL] Missing ${TCL_SCRIPT}" >&2
    exit 1
fi

echo "============================================================"
echo " CIM chip synthesis"
echo "============================================================"
echo "  SYN_DIR    : ${SYN_DIR}"
echo "  CORNER_ID  : ${CORNER_ID}"
echo "  OUT_TAG    : ${OUT_TAG}"
echo "  CLK_PERIOD : ${CLK_PERIOD} ns"
echo "  DC_BIN     : ${DC_BIN}"
echo "  LOG_FILE   : ${LOG_FILE}"
echo "============================================================"

"${DC_BIN}" \
    -x "set CORNER_ID ${CORNER_ID}; set OUT_TAG ${OUT_TAG}; set CLK_PERIOD ${CLK_PERIOD}" \
    -f "${TCL_SCRIPT}" 2>&1 | tee "${LOG_FILE}"

rc=${PIPESTATUS[0]}

if grep -q "========== cim_chip @ .* done ==========" "${LOG_FILE}"; then
    echo "[OK] cim_chip synthesis completed."
    exit 0
fi

echo "[FAIL] cim_chip synthesis failed. See ${LOG_FILE}" >&2
exit "${rc}"
