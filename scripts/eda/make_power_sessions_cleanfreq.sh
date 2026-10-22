#!/usr/bin/env bash
# ==============================================================================
# File    : make_power_sessions_cleanfreq.sh
# Purpose : Create PT/PrimePower sessions for each design/tag listed in
#           clean_periods.tsv using its clean_period_ns.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/make_power_sessions_cleanfreq.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x make_power_sessions_cleanfreq.sh
#
#   # Check only:
#   ./check_power_sessions_cleanfreq.sh
#
#   # Create missing sessions only:
#   ilaunch ./make_power_sessions_cleanfreq.sh
#
#   # Force rebuild all sessions:
#   FORCE=1 ilaunch ./make_power_sessions_cleanfreq.sh
#
# Optional filters:
#   KEYS="top_hier abl_mf abl_mult" ilaunch ./make_power_sessions_cleanfreq.sh
#   TAGS="abl_mf_tt0p9v25c abl_mult_tt0p9v25c" ilaunch ./make_power_sessions_cleanfreq.sh
#
# Assumes:
#   ${PROJ_ROOT}/make_power_session_case.sh exists and supports:
#     DESIGN_NAME=<...> TAG=<...> POWER_PERIOD=<...> ./make_power_session_case.sh
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. Run it from sim/ or anywhere; it cd's to PROJ_ROOT before calling
#      make_power_session_case.sh.
#   3. After hold ECO, update clean_periods.tsv and rerun this script.
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
PT_DIR=${PT_DIR:-"${PROJ_ROOT}/pt"}
PERIOD_CFG=${PERIOD_CFG:-"${SIM_DIR}/energy_tb/configs/clean_periods.tsv"}
MAKE_SCRIPT=${MAKE_SCRIPT:-"${PROJ_ROOT}/make_power_session_case.sh"}
LOG_ROOT=${LOG_ROOT:-"${PROJ_ROOT}/pt/session_build_logs"}
FORCE=${FORCE:-0}
KEYS=${KEYS:-""}
TAGS=${TAGS:-""}

mkdir -p "${LOG_ROOT}"

if [[ ! -f "${PERIOD_CFG}" ]]; then
    echo "[FATAL] Missing clean period config: ${PERIOD_CFG}" >&2
    exit 1
fi

if [[ ! -x "${MAKE_SCRIPT}" ]]; then
    echo "[FATAL] Missing or non-executable make script: ${MAKE_SCRIPT}" >&2
    echo "        Try: chmod +x ${MAKE_SCRIPT}" >&2
    exit 1
fi

period_tag() {
    local p="$1"
    echo "${p/./p}"
}

has_word() {
    local list="$1"
    local word="$2"
    [[ -z "${list}" ]] && return 0
    local x
    for x in ${list}; do
        [[ "${x}" == "${word}" ]] && return 0
    done
    return 1
}

session_exists() {
    local tag="$1"
    local p="$2"
    local pt="${p/./p}"
    local base="${PT_DIR}/runs_${tag}_power"
    local cands=(
        "${base}/pt_session_${tag}_${pt}ns"
        "${base}/pt_session_${tag}_${pt}"
        "${base}/pt_session_${tag}"
    )
    local c
    for c in "${cands[@]}"; do
        if [[ -d "${c}" ]]; then
            echo "${c}"
            return 0
        fi
    done
    return 1
}

echo "======================================================================"
echo " [MAKE POWER SESSIONS @ CLEAN PERIODS]"
echo "======================================================================"
echo "  PROJ_ROOT  : ${PROJ_ROOT}"
echo "  PERIOD_CFG : ${PERIOD_CFG}"
echo "  MAKE_SCRIPT: ${MAKE_SCRIPT}"
echo "  FORCE      : ${FORCE}"
echo "  KEYS       : ${KEYS:-<all>}"
echo "  TAGS       : ${TAGS:-<all>}"
echo "  LOG_ROOT   : ${LOG_ROOT}"
echo "======================================================================"

pass=0
skip=0
fail=0

while IFS=$'\t' read -r key tag design_name clean_period_ns note; do
    [[ -z "${key:-}" ]] && continue
    [[ "${key}" =~ ^# ]] && continue
    [[ "${key}" == "key" ]] && continue

    if ! has_word "${KEYS}" "${key}"; then
        continue
    fi
    if ! has_word "${TAGS}" "${tag}"; then
        continue
    fi

    ptag=$(period_tag "${clean_period_ns}")
    log="${LOG_ROOT}/make_session_${tag}_${ptag}ns.log"

    found=""
    if found=$(session_exists "${tag}" "${clean_period_ns}"); then
        if [[ "${FORCE}" != "1" ]]; then
            echo "[SKIP] ${key}/${tag} period=${clean_period_ns}ns session exists: ${found}"
            skip=$((skip + 1))
            continue
        else
            echo "[FORCE] Rebuilding ${key}/${tag} period=${clean_period_ns}ns; existing: ${found}"
        fi
    fi

    echo ""
    echo "----------------------------------------------------------------------"
    echo "[BUILD] key=${key} tag=${tag} design=${design_name} period=${clean_period_ns}ns"
    echo "----------------------------------------------------------------------"

    cd "${PROJ_ROOT}"

    if DESIGN_NAME="${design_name}" TAG="${tag}" POWER_PERIOD="${clean_period_ns}" \
        "${MAKE_SCRIPT}" | tee "${log}"; then

        new_found=""
        if new_found=$(session_exists "${tag}" "${clean_period_ns}"); then
            echo "[OK] Built/found session: ${new_found}"
            pass=$((pass + 1))
        else
            echo "[FAIL] make script exited OK but no matching session found for ${tag} ${clean_period_ns}ns" >&2
            echo "       See log: ${log}" >&2
            fail=$((fail + 1))
        fi
    else
        echo "[FAIL] Failed to build session for ${tag} ${clean_period_ns}ns; see ${log}" >&2
        fail=$((fail + 1))
    fi

done < "${PERIOD_CFG}"

echo ""
echo "======================================================================"
echo " [MAKE POWER SESSIONS SUMMARY]"
echo "======================================================================"
echo "  PASS : ${pass}"
echo "  SKIP : ${skip}"
echo "  FAIL : ${fail}"
echo "======================================================================"

# Write a final check table if checker exists.
if [[ -x "${SIM_DIR}/check_power_sessions_cleanfreq.sh" ]]; then
    "${SIM_DIR}/check_power_sessions_cleanfreq.sh" || true
fi

if [[ ${fail} -ne 0 ]]; then
    exit 1
fi
exit 0
