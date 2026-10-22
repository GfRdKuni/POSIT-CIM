#!/usr/bin/env bash
# ==============================================================================
# File    : run_ablation_syn.sh
# Project : posit_cim_28nm
# Purpose : TT-corner mixed-Vt synthesis driver for cim_top ablations.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/syn/run_ablation_syn.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/syn
#   chmod +x run_ablation_syn.sh
#   ilaunch ./run_ablation_syn.sh
#
# Examples:
#   ABLATIONS="mult dec" ilaunch ./run_ablation_syn.sh
#   CLK_PERIOD=2.6 ilaunch ./run_ablation_syn.sh
#   KEEP_HIER=0 ilaunch ./run_ablation_syn.sh
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. Default KEEP_HIER=1 because ablation is mainly for module-level comparison.
#   3. Default corner is tt0p9v25c.
# ==============================================================================

set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SYN_DIR=${SYN_DIR:-"${PROJ_ROOT}/syn"}
DC_BIN=${DC_BIN:-"dc_shell"}

CORNER_ID=${CORNER_ID:-"tt0p9v25c"}
CLK_PERIOD=${CLK_PERIOD:-"2.8"}
KEEP_HIER=${KEEP_HIER:-1}
ABLATIONS=${ABLATIONS:-"mult mf dec"}
PARALLEL=${PARALLEL:-0}

cd "${SYN_DIR}" || { echo "[FATAL] Cannot cd to ${SYN_DIR}" >&2; exit 1; }

LOGDIR="logs_ablation_${CORNER_ID}"
mkdir -p "${LOGDIR}"

echo "============================================================"
echo " CIM ablation synthesis driver"
echo "============================================================"
echo "  SYN_DIR    : ${SYN_DIR}"
echo "  CORNER_ID  : ${CORNER_ID}"
echo "  CLK_PERIOD : ${CLK_PERIOD} ns"
echo "  KEEP_HIER  : ${KEEP_HIER}"
echo "  ABLATIONS  : ${ABLATIONS}"
echo "  PARALLEL   : ${PARALLEL}"
echo "  DC_BIN     : ${DC_BIN}"
echo "  LOGDIR     : ${LOGDIR}"
echo "============================================================"

run_one() {
    local abl="$1"
    local tag="abl_${abl}"
    local tcl="syn_abl_${abl}.tcl"
    local out_tag="${tag}_${CORNER_ID}"
    local log="${LOGDIR}/syn_${out_tag}.log"

    if [[ ! -f "${tcl}" ]]; then
        echo "[FAIL] ${abl}: Tcl not found: ${tcl}" >&2
        return 1
    fi

    echo ""
    echo ">>> [${abl}] ${DC_BIN} -f ${tcl}"
    echo "    OUT_TAG=${out_tag}"
    echo "    LOG=${log}"

    "${DC_BIN}" \
        -x "set CORNER_ID ${CORNER_ID}; set OUT_TAG ${out_tag}; set KEEP_HIER ${KEEP_HIER}; set CLK_PERIOD ${CLK_PERIOD}" \
        -f "${tcl}" 2>&1 | tee "${log}"

    local rc=${PIPESTATUS[0]}

    if grep -q "========== .* done ==========" "${log}"; then
        return 0
    fi
    return "${rc}"
}

for abl in ${ABLATIONS}; do
    case "${abl}" in
        mult|mf|dec) ;;
        *) echo "[FATAL] Unknown ablation '${abl}' (expected mult/mf/dec)" >&2; exit 1 ;;
    esac
done

declare -A RC
START_TIME=$SECONDS

if [[ "${PARALLEL}" == "1" ]]; then
    declare -A PIDS
    for abl in ${ABLATIONS}; do
        ( run_one "${abl}"; echo $? > "${LOGDIR}/.rc_${abl}" ) &
        PIDS[${abl}]=$!
    done
    for abl in "${!PIDS[@]}"; do
        wait "${PIDS[${abl}]}" || true
        RC[${abl}]=$(<"${LOGDIR}/.rc_${abl}")
        rm -f "${LOGDIR}/.rc_${abl}"
    done
else
    for abl in ${ABLATIONS}; do
        if run_one "${abl}"; then
            RC[${abl}]=0
        else
            RC[${abl}]=$?
            echo "[WARN] ablation '${abl}' returned ${RC[${abl}]}, continuing." >&2
        fi
    done
fi

ELAPSED=$((SECONDS - START_TIME))

echo ""
echo "============================================================"
echo " Summary (elapsed: ${ELAPSED}s)"
echo "============================================================"
fail=0
for abl in ${ABLATIONS}; do
    rc=${RC[${abl}]:-?}
    tag="abl_${abl}_${CORNER_ID}"
    if [[ "${rc}" == "0" ]]; then
        echo "  [OK]   ${tag} -- reports_${tag}/, outputs_${tag}/"
    else
        echo "  [FAIL] ${tag} -- rc=${rc}, see ${LOGDIR}/syn_${tag}.log"
        fail=1
    fi
done
echo "============================================================"

exit "${fail}"
