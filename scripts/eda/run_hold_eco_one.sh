#!/usr/bin/env bash
# ==============================================================================
# File    : run_hold_eco_one.sh
# Purpose : Run Innovus post-route hold ECO for one single-core design.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/pnr/run_hold_eco_one.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/pnr
#   chmod +x run_hold_eco_one.sh
#
#   # top_hier
#   ilaunch ./run_hold_eco_one.sh top_hier
#
#   # abl_mf
#   ilaunch ./run_hold_eco_one.sh mf
#
#   # abl_mult
#   ilaunch ./run_hold_eco_one.sh mult
#
#   # abl_dec after it is fixed
#   ilaunch ./run_hold_eco_one.sh dec
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. By default it writes to a NEW tag: ${TAG}_holdfix.
#   3. It restores pnr/runs_${TAG}/outputs/${DESIGN_NAME}_${TAG}_routed.enc.
# ==============================================================================

set -e
set -u
set -o pipefail

MODE=${1:-"mf"}   # top_hier|top|mf|mult|dec|custom

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
PNR_DIR=${PNR_DIR:-"${PROJ_ROOT}/pnr"}

INNOVUS_BIN=${INNOVUS_BIN:-"innovus"}
HOLD_ITER=${HOLD_ITER:-2}
SETUP_CHECK=${SETUP_CHECK:-1}
DO_GDS=${DO_GDS:-1}

CORNER_ID=${CORNER_ID:-"tt0p9v25c"}
TOP_HIER_TAG=${TOP_HIER_TAG:-"tt_0p90v_0p90v_25c_hier"}

GDS_MAP=${GDS_MAP:-"/path/to/licensed_pdk/tsmcN28/PRTF_EDI_28nm_Cad_V19_1a/PR_tech/Cadence/GdsOutMap/gdsout_7X2R.map"}

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

OUT_TAG=${OUT_TAG:-"${TAG}_holdfix"}

IN_RUN_DIR="${PNR_DIR}/runs_${TAG}"
IN_OUT_DIR="${IN_RUN_DIR}/outputs"
RESTORE_ENC=${RESTORE_ENC:-"${IN_OUT_DIR}/${NETLIST_TOP}_${TAG}_routed.enc"}

HOLD_RUN_DIR="${PNR_DIR}/runs_${OUT_TAG}"
OUT_DIR="${HOLD_RUN_DIR}/outputs"
REPORT_DIR="${HOLD_RUN_DIR}/reports"
LOG_DIR="${HOLD_RUN_DIR}/logs"

mkdir -p "${OUT_DIR}" "${REPORT_DIR}" "${LOG_DIR}"

TCL="${PNR_DIR}/hold_eco_from_routed.tcl"
if [[ ! -f "${TCL}" ]]; then
    echo "[FATAL] Missing Tcl script: ${TCL}" >&2
    exit 1
fi

if [[ ! -f "${RESTORE_ENC}" && ! -d "${RESTORE_ENC}.dat" && ! -d "${RESTORE_ENC}" ]]; then
    echo "[FATAL] Cannot find routed Innovus DB:" >&2
    echo "        RESTORE_ENC=${RESTORE_ENC}" >&2
    echo "        Also checked ${RESTORE_ENC}.dat" >&2
    exit 1
fi

echo "======================================================================"
echo " [RUN HOLD ECO ONE]"
echo "======================================================================"
echo " KEY          : ${KEY}"
echo " TAG          : ${TAG}"
echo " OUT_TAG      : ${OUT_TAG}"
echo " DESIGN_NAME  : ${DESIGN_NAME}"
echo " NETLIST_TOP  : ${NETLIST_TOP}"
echo " RESTORE_ENC  : ${RESTORE_ENC}"
echo " HOLD_ITER    : ${HOLD_ITER}"
echo " SETUP_CHECK  : ${SETUP_CHECK}"
echo " DO_GDS       : ${DO_GDS}"
echo " GDS_MAP      : ${GDS_MAP}"
echo " HOLD_RUN_DIR : ${HOLD_RUN_DIR}"
echo "======================================================================"

DESIGN_NAME="${DESIGN_NAME}" \
TAG="${TAG}" \
OUT_TAG="${OUT_TAG}" \
RESTORE_ENC="${RESTORE_ENC}" \
OUT_DIR="${OUT_DIR}" \
REPORT_DIR="${REPORT_DIR}" \
HOLD_ITER="${HOLD_ITER}" \
SETUP_CHECK="${SETUP_CHECK}" \
DO_GDS="${DO_GDS}" \
GDS_MAP="${GDS_MAP}" \
"${INNOVUS_BIN}" -nowin -init "${TCL}" \
    -log "${LOG_DIR}/hold_eco_${OUT_TAG}.log" \
    -cmd "${LOG_DIR}/hold_eco_${OUT_TAG}.cmd"

echo "[DONE] Hold ECO finished for ${KEY}/${TAG}"
echo "       Outputs: ${OUT_DIR}"
echo "       Reports: ${REPORT_DIR}"
