#!/usr/bin/env bash
# ==============================================================================
# File    : run_energy_mnist_sparse_sweep_cleanfreq.sh
# Purpose : Sweep design x regime x A sparsity x W sparsity at per-design
#           timing-clean period/frequency.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/run_energy_mnist_sparse_sweep_cleanfreq.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x run_energy_mnist_sparse_sweep_cleanfreq.sh
#
#   # Smoke
#   DESIGNS="mf" REGIMES="p16_l1" A_SPARSITIES="0 50" W_SPARSITIES="0 50" MAX_OPS=1 \
#   ilaunch ./run_energy_mnist_sparse_sweep_cleanfreq.sh
#
#   # Full single-core sweep after periods are finalized
#   DESIGNS="top_hier mf mult" MAX_OPS=8 \
#   ilaunch ./run_energy_mnist_sparse_sweep_cleanfreq.sh
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. It calls ./run_energy_mnist_sparse_gls.sh.
#   3. Each design uses the clean_period_ns from clean_periods.tsv.
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
PERIOD_CFG=${PERIOD_CFG:-"${SIM_DIR}/energy_tb/configs/clean_periods.tsv"}

DESIGNS=${DESIGNS:-"top_hier mf mult"}
REGIMES=${REGIMES:-"p16_l1 p16_l2 p8_l1"}
A_SPARSITIES=${A_SPARSITIES:-"0 25 50 75 90"}
W_SPARSITIES=${W_SPARSITIES:-"0 25 50 75 90"}
SEED=${SEED:-1}
MAX_OPS=${MAX_OPS:-8}
LOG_DIR=${LOG_DIR:-"${SIM_DIR}/energy_sweep_logs_cleanfreq"}

cd "${SIM_DIR}" || { echo "[FATAL] Cannot cd to ${SIM_DIR}" >&2; exit 1; }

if [[ ! -f "${PERIOD_CFG}" ]]; then
    echo "[FATAL] Missing period config: ${PERIOD_CFG}" >&2
    echo "        Create sim/energy_tb/configs/clean_periods.tsv first." >&2
    exit 1
fi

if [[ ! -x "${SIM_DIR}/run_energy_mnist_sparse_gls.sh" ]]; then
    echo "[FATAL] Missing executable ${SIM_DIR}/run_energy_mnist_sparse_gls.sh" >&2
    exit 1
fi

mkdir -p "${LOG_DIR}"

# Map user-facing design key to clean_periods.tsv key.
norm_key() {
    case "$1" in
        top|top_hier) echo "top_hier" ;;
        mf|abl_mf) echo "abl_mf" ;;
        mult|abl_mult) echo "abl_mult" ;;
        dec|abl_dec) echo "abl_dec" ;;
        *) echo "$1" ;;
    esac
}

period_for_design() {
    local user_key="$1"
    local key
    key=$(norm_key "${user_key}")
    awk -F'\t' -v k="${key}" '
        BEGIN { found=0 }
        /^[[:space:]]*#/ { next }
        NF < 4 { next }
        $1 == k {
            print $4
            found=1
            exit
        }
        END {
            if (!found) exit 2
        }
    ' "${PERIOD_CFG}"
}

echo "======================================================================"
echo " [MNIST SPARSE SWEEP @ CLEAN PER-DESIGN FREQUENCY]"
echo "======================================================================"
echo "  PERIOD_CFG     = ${PERIOD_CFG}"
echo "  DESIGNS        = ${DESIGNS}"
echo "  REGIMES        = ${REGIMES}"
echo "  A_SPARSITIES   = ${A_SPARSITIES}"
echo "  W_SPARSITIES   = ${W_SPARSITIES}"
echo "  SEED           = ${SEED}"
echo "  MAX_OPS        = ${MAX_OPS}"
echo "  LOG_DIR        = ${LOG_DIR}"
echo "======================================================================"

pass=0
fail=0

for design in ${DESIGNS}; do
    period_ns=$(period_for_design "${design}") || {
        echo "[FATAL] No clean period found for design=${design} in ${PERIOD_CFG}" >&2
        exit 1
    }

    echo "[INFO] design=${design} clean_period_ns=${period_ns}"

    for regime in ${REGIMES}; do
        for asp in ${A_SPARSITIES}; do
            for wsp in ${W_SPARSITIES}; do
                asp3=$(printf "%03d" "${asp}")
                wsp3=$(printf "%03d" "${wsp}")
                log="${LOG_DIR}/run_energy_${design}_${regime}_a${asp3}_w${wsp3}_seed${SEED}.log"

                echo ""
                echo "======================================================================"
                echo "[RUN] design=${design} regime=${regime} A=${asp} W=${wsp} seed=${SEED} period=${period_ns}ns"
                echo "======================================================================"

                if MAX_OPS="${MAX_OPS}" CLK_PERIOD_NS="${period_ns}" \
                    "${SIM_DIR}/run_energy_mnist_sparse_gls.sh" "${design}" "${regime}" "${asp}" "${wsp}" "${SEED}" \
                    | tee "${log}"
                then
                    echo "[OK] ${design} ${regime} A=${asp} W=${wsp} period=${period_ns}ns"
                    pass=$((pass + 1))
                else
                    echo "[FAIL] ${design} ${regime} A=${asp} W=${wsp} period=${period_ns}ns"
                    fail=$((fail + 1))
                fi
            done
        done
    done
done

echo ""
echo "======================================================================"
echo " [SWEEP SUMMARY]"
echo "======================================================================"
echo "  PASS = ${pass}"
echo "  FAIL = ${fail}"
echo "======================================================================"

if [[ ${fail} -ne 0 ]]; then
    exit 1
fi
exit 0
