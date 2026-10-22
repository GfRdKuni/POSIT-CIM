#!/usr/bin/env bash
# ==============================================================================
# File    : run_innovus_chip.sh
# Project : posit_cim_28nm
# Purpose : Batch driver for Innovus P&R of 16-core cim_chip.
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/pnr
#   chmod +x run_innovus_chip.sh
#   ilaunch ./run_innovus_chip.sh
#
# If congestion is heavy:
#   DIE_W=2200 DIE_H=2200 PLACE_DENSITY=0.50 ilaunch ./run_innovus_chip.sh
#
# This script does NOT call ilaunch internally.
# ==============================================================================

set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
PNR_DIR=${PNR_DIR:-"${PROJ_ROOT}/pnr"}
TCL_SCRIPT=${TCL_SCRIPT:-"${PNR_DIR}/run_innovus_chip_core.tcl"}
INNOVUS_BIN=${INNOVUS_BIN:-"innovus"}

DESIGN_NAME=${DESIGN_NAME:-"cim_chip"}
CORNER_ID=${CORNER_ID:-"tt0p9v25c"}
OUT_TAG=${OUT_TAG:-"chip_${CORNER_ID}"}

DIE_W=${DIE_W:-"2000.0"}
DIE_H=${DIE_H:-"2000.0"}
CORE_MARGIN=${CORE_MARGIN:-"80.0"}
PLACE_DENSITY=${PLACE_DENSITY:-"0.55"}

QRC_TECH_FILE=${QRC_TECH_FILE:-""}
CAP_TABLE=${CAP_TABLE:-""}
ROUTE_TIMING_DRIVEN=${ROUTE_TIMING_DRIVEN:-"true"}

mkdir -p "${PNR_DIR}"
cd "${PNR_DIR}" || { echo "[FATAL] Cannot cd to ${PNR_DIR}" >&2; exit 1; }

if [[ ! -f "${TCL_SCRIPT}" ]]; then
    echo "[FATAL] Missing Tcl script: ${TCL_SCRIPT}" >&2
    exit 1
fi

netlist="${PROJ_ROOT}/syn/outputs_${OUT_TAG}/${DESIGN_NAME}_${OUT_TAG}.v"
sdc="${PROJ_ROOT}/syn/outputs_${OUT_TAG}/${DESIGN_NAME}_${OUT_TAG}.sdc"

if [[ ! -f "${netlist}" ]]; then
    echo "[FATAL] Missing chip netlist: ${netlist}" >&2
    exit 1
fi
if [[ ! -f "${sdc}" ]]; then
    echo "[FATAL] Missing chip SDC: ${sdc}" >&2
    exit 1
fi

log="innovus_${OUT_TAG}.log"

echo "======================================================================"
echo " Innovus cim_chip P&R driver"
echo "======================================================================"
echo " PROJ_ROOT           : ${PROJ_ROOT}"
echo " PNR_DIR             : ${PNR_DIR}"
echo " TCL_SCRIPT          : ${TCL_SCRIPT}"
echo " INNOVUS_BIN         : ${INNOVUS_BIN}"
echo " DESIGN_NAME         : ${DESIGN_NAME}"
echo " CORNER_ID           : ${CORNER_ID}"
echo " OUT_TAG             : ${OUT_TAG}"
echo " NETLIST             : ${netlist}"
echo " SDC                 : ${sdc}"
echo " DIE_W/H             : ${DIE_W} / ${DIE_H}"
echo " CORE_MARGIN         : ${CORE_MARGIN}"
echo " PLACE_DENSITY       : ${PLACE_DENSITY}"
echo " ROUTE_TIMING_DRIVEN : ${ROUTE_TIMING_DRIVEN}"
echo " QRC_TECH_FILE       : ${QRC_TECH_FILE}"
echo " CAP_TABLE           : ${CAP_TABLE}"
echo " LOG                 : ${PNR_DIR}/${log}"
echo "======================================================================"

"${INNOVUS_BIN}" -nowin -init "${TCL_SCRIPT}" \
    -execute "set DESIGN_NAME ${DESIGN_NAME}; set OUT_TAG ${OUT_TAG}; set CORNER_ID ${CORNER_ID}; set DIE_W ${DIE_W}; set DIE_H ${DIE_H}; set CORE_MARGIN ${CORE_MARGIN}; set PLACE_DENSITY ${PLACE_DENSITY}; set QRC_TECH_FILE {${QRC_TECH_FILE}}; set CAP_TABLE {${CAP_TABLE}}; set ROUTE_TIMING_DRIVEN ${ROUTE_TIMING_DRIVEN}" \
    -log "${log}"

rc=$?

if grep -q "Innovus P&R completed" "${log}" 2>/dev/null; then
    echo "[OK] ${DESIGN_NAME}/${OUT_TAG} completed."
    exit 0
fi

echo "[FAIL] ${DESIGN_NAME}/${OUT_TAG} failed or did not reach completion marker. See ${PNR_DIR}/${log}" >&2
exit "${rc}"
