#!/usr/bin/env bash
# ==============================================================================
# File    : check_power_sessions_cleanfreq.sh
# Purpose : Check whether each design/tag in clean_periods.tsv has a matching
#           PT/PrimePower session directory for its clean_period_ns.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/check_power_sessions_cleanfreq.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x check_power_sessions_cleanfreq.sh
#   ./check_power_sessions_cleanfreq.sh
#
# Output:
#   ../results/energy_workloads/power_session_check.tsv
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
PT_DIR=${PT_DIR:-"${PROJ_ROOT}/pt"}
PERIOD_CFG=${PERIOD_CFG:-"${SIM_DIR}/energy_tb/configs/clean_periods.tsv"}
OUT_DIR=${OUT_DIR:-"${PROJ_ROOT}/results/energy_workloads"}
OUT="${OUT_DIR}/power_session_check.tsv"

mkdir -p "${OUT_DIR}"

if [[ ! -f "${PERIOD_CFG}" ]]; then
    echo "[FATAL] Missing clean period config: ${PERIOD_CFG}" >&2
    exit 1
fi

period_tag() {
    local p="$1"
    echo "${p/./p}"
}

session_candidates() {
    local tag="$1"
    local p="$2"
    local pt="${p/./p}"
    local base="${PT_DIR}/runs_${tag}_power"

    echo "${base}/pt_session_${tag}_${pt}ns"
    echo "${base}/pt_session_${tag}_${pt}"
    echo "${base}/pt_session_${tag}"
}

echo -e "key\ttag\tdesign_name\tclean_period_ns\texpected_session\tstatus\tfound_session" > "${OUT}"

while IFS=$'\t' read -r key tag design_name clean_period_ns note; do
    [[ -z "${key:-}" ]] && continue
    [[ "${key}" =~ ^# ]] && continue
    [[ "${key}" == "key" ]] && continue

    found=""
    expected="${PT_DIR}/runs_${tag}_power/pt_session_${tag}_$(period_tag "${clean_period_ns}")ns"

    while IFS= read -r cand; do
        if [[ -d "${cand}" ]]; then
            found="${cand}"
            break
        fi
    done < <(session_candidates "${tag}" "${clean_period_ns}")

    if [[ -n "${found}" ]]; then
        status="FOUND"
    else
        status="MISSING"
    fi

    echo -e "${key}\t${tag}\t${design_name}\t${clean_period_ns}\t${expected}\t${status}\t${found}" >> "${OUT}"

done < "${PERIOD_CFG}"

echo "[DONE] Wrote ${OUT}"
echo
column -t -s $'\t' "${OUT}" || cat "${OUT}"

missing=$(awk -F'\t' 'NR>1 && $6=="MISSING"{c++} END{print c+0}' "${OUT}")
if [[ "${missing}" -ne 0 ]]; then
    echo
    echo "[WARN] Missing sessions: ${missing}"
    exit 2
fi

exit 0
