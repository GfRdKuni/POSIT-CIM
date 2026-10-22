#!/usr/bin/env bash
# ==============================================================================
# File    : run_innovus_ablation.sh
# Project : posit_cim_28nm
# Purpose : Batch driver for Innovus P&R of cim_top and TT ablation cores.
# ==============================================================================

set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
PNR_DIR=${PNR_DIR:-"${PROJ_ROOT}/pnr"}
TCL_SCRIPT=${TCL_SCRIPT:-"${PNR_DIR}/run_innovus_ablation_core.tcl"}
INNOVUS_BIN=${INNOVUS_BIN:-"innovus"}

CORNER_ID=${CORNER_ID:-"tt0p9v25c"}
DESIGNS=${DESIGNS:-"dec"}

DIE_W=${DIE_W:-"400.0"}
DIE_H=${DIE_H:-"400.0"}
CORE_MARGIN=${CORE_MARGIN:-"20.0"}
PLACE_DENSITY=${PLACE_DENSITY:-"0.65"}

QRC_TECH_FILE=${QRC_TECH_FILE:-""}
CAP_TABLE=${CAP_TABLE:-""}

mkdir -p "${PNR_DIR}"
cd "${PNR_DIR}" || { echo "[FATAL] Cannot cd to ${PNR_DIR}" >&2; exit 1; }

if [[ ! -f "${TCL_SCRIPT}" ]]; then
    echo "[FATAL] Missing Tcl script: ${TCL_SCRIPT}" >&2
    exit 1
fi

echo "======================================================================"
echo " Innovus ablation P&R driver"
echo "======================================================================"
echo " PROJ_ROOT     : ${PROJ_ROOT}"
echo " PNR_DIR       : ${PNR_DIR}"
echo " TCL_SCRIPT    : ${TCL_SCRIPT}"
echo " INNOVUS_BIN   : ${INNOVUS_BIN}"
echo " CORNER_ID     : ${CORNER_ID}"
echo " DESIGNS       : ${DESIGNS}"
echo " DIE_W/H       : ${DIE_W} / ${DIE_H}"
echo " CORE_MARGIN   : ${CORE_MARGIN}"
echo " PLACE_DENSITY : ${PLACE_DENSITY}"
echo " QRC_TECH_FILE : ${QRC_TECH_FILE}"
echo " CAP_TABLE     : ${CAP_TABLE}"
echo "======================================================================"

map_design() {
    local key="$1"
    case "${key}" in
        top)  echo "cim_top ${CORNER_ID}" ;;
        dec)  echo "cim_top_abl_dec abl_dec_${CORNER_ID}" ;;
        mf)   echo "cim_top_abl_mf abl_mf_${CORNER_ID}" ;;
        mult) echo "cim_top_abl_mult abl_mult_${CORNER_ID}" ;;
        *)    echo "" ;;
    esac
}

run_one() {
    local key="$1"
    local mapped design tag netlist sdc log rc

    mapped="$(map_design "${key}")"
    if [[ -z "${mapped}" ]]; then
        echo "[FATAL] Unknown design key '${key}'. Use top/dec/mf/mult." >&2
        return 1
    fi

    design="$(echo "${mapped}" | awk '{print $1}')"
    tag="$(echo "${mapped}" | awk '{print $2}')"

    netlist="${PROJ_ROOT}/syn/outputs_${tag}/${design}_${tag}.v"
    sdc="${PROJ_ROOT}/syn/outputs_${tag}/${design}_${tag}.sdc"

    if [[ ! -f "${netlist}" ]]; then
        echo "[FAIL] Missing netlist for ${key}: ${netlist}" >&2
        return 1
    fi
    if [[ ! -f "${sdc}" ]]; then
        echo "[FAIL] Missing SDC for ${key}: ${sdc}" >&2
        return 1
    fi

    log="innovus_${tag}.log"

    echo ""
    echo "----------------------------------------------------------------------"
    echo " Running Innovus"
    echo "----------------------------------------------------------------------"
    echo " key         : ${key}"
    echo " DESIGN_NAME : ${design}"
    echo " OUT_TAG     : ${tag}"
    echo " NETLIST     : ${netlist}"
    echo " SDC         : ${sdc}"
    echo " LOG         : ${PNR_DIR}/${log}"
    echo "----------------------------------------------------------------------"

    "${INNOVUS_BIN}" -nowin -init "${TCL_SCRIPT}" \
        -execute "set DESIGN_NAME ${design}; set OUT_TAG ${tag}; set CORNER_ID ${CORNER_ID}; set DIE_W ${DIE_W}; set DIE_H ${DIE_H}; set CORE_MARGIN ${CORE_MARGIN}; set PLACE_DENSITY ${PLACE_DENSITY}; set QRC_TECH_FILE {${QRC_TECH_FILE}}; set CAP_TABLE {${CAP_TABLE}}" \
        -log "${log}"

    rc=$?

    if grep -q "Innovus P&R completed" "${log}" 2>/dev/null; then
        echo "[OK] ${design}/${tag} completed."
        return 0
    fi

    echo "[FAIL] ${design}/${tag} failed or did not reach completion marker. See ${PNR_DIR}/${log}" >&2
    return "${rc}"
}

fail=0
for d in ${DESIGNS}; do
    if ! run_one "${d}"; then
        fail=$((fail + 1))
        echo "[WARN] Design key '${d}' failed; continuing with next design." >&2
    fi
done

echo ""
echo "======================================================================"
if [[ "${fail}" -eq 0 ]]; then
    echo " [DONE] All requested Innovus runs completed."
else
    echo " [DONE] Innovus runs finished with ${fail} failure(s)."
fi
echo "======================================================================"

exit "${fail}"
