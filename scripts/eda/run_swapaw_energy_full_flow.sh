#!/usr/bin/env bash
# ==============================================================================
# File    : run_swapaw_energy_full_flow.sh
# Purpose : One-command SWAP-A/W workload-placement energy flow.
#
# It can run:
#   1) swapaw GLS sweep
#   2) VCD -> SAIF
#   3) PrimePower workload power
#   4) collect energy summary
#   5) extract trend tables
#   6) plot sparsity evidence
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#
#   # Full flow:
#   DO_GLS=1 DO_SAIF=1 DO_POWER=1 DO_COLLECT=1 DO_TRENDS=1 DO_PLOT=1 \
#   ilaunch ./run_swapaw_energy_full_flow.sh
#
#   # If GLS already done:
#   DO_GLS=0 DO_SAIF=1 DO_POWER=1 DO_COLLECT=1 DO_TRENDS=1 DO_PLOT=1 \
#   ilaunch ./run_swapaw_energy_full_flow.sh
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}

TAGS=${TAGS:-"tt_0p90v_0p90v_25c_hier abl_mf_tt0p9v25c abl_mult_tt0p9v25c abl_dec_tt0p9v25c"}

DESIGNS=${DESIGNS:-"top_hier mf mult dec"}
REGIMES=${REGIMES:-"p16_l1 p16_l2 p8_l1"}
A_SPARSITIES=${A_SPARSITIES:-"0 25 50 75 90"}
W_SPARSITIES=${W_SPARSITIES:-"0 25 50 75 90"}
MAX_OPS=${MAX_OPS:-8}
SEED=${SEED:-1}

DO_GLS=${DO_GLS:-1}
DO_SAIF=${DO_SAIF:-1}
DO_POWER=${DO_POWER:-1}
DO_COLLECT=${DO_COLLECT:-1}
DO_TRENDS=${DO_TRENDS:-1}
DO_PLOT=${DO_PLOT:-1}
FORCE=${FORCE:-0}

cd "${SIM_DIR}"

echo "======================================================================"
echo " [SWAP-AW ENERGY FULL FLOW]"
echo "======================================================================"
echo "  PROJ_ROOT    : ${PROJ_ROOT}"
echo "  SIM_DIR      : ${SIM_DIR}"
echo "  TAGS         : ${TAGS}"
echo "  DESIGNS      : ${DESIGNS}"
echo "  REGIMES      : ${REGIMES}"
echo "  A_SPARSITIES : ${A_SPARSITIES}"
echo "  W_SPARSITIES : ${W_SPARSITIES}"
echo "  MAX_OPS      : ${MAX_OPS}"
echo "  SEED         : ${SEED}"
echo "  FORCE        : ${FORCE}"
echo "  DO_GLS       : ${DO_GLS}"
echo "  DO_SAIF      : ${DO_SAIF}"
echo "  DO_POWER     : ${DO_POWER}"
echo "  DO_COLLECT   : ${DO_COLLECT}"
echo "  DO_TRENDS    : ${DO_TRENDS}"
echo "  DO_PLOT      : ${DO_PLOT}"
echo "======================================================================"

if [[ "${DO_GLS}" == "1" ]]; then
    echo "[STEP] GLS sweep"
    module purge || true
    module load vcs/2022.06-SP2

    DESIGNS="${DESIGNS}" \
    REGIMES="${REGIMES}" \
    A_SPARSITIES="${A_SPARSITIES}" \
    W_SPARSITIES="${W_SPARSITIES}" \
    MAX_OPS="${MAX_OPS}" \
    SEED="${SEED}" \
    "${SIM_DIR}/run_energy_mnist_sparse_sweep_cleanfreq_swapaw.sh" \
      | tee "${SIM_DIR}/run_energy_mnist_sparse_sweep_cleanfreq_swapaw.log"
fi

if [[ "${DO_SAIF}" == "1" ]]; then
    echo "[STEP] VCD -> SAIF"
    module purge || true
    module load vcs/2022.06-SP2

    TAGS="${TAGS}" FORCE="${FORCE}" \
    "${SIM_DIR}/run_energy_vcd2saif_all_swapaw.sh" \
      | tee "${SIM_DIR}/run_energy_vcd2saif_all_swapaw.log"
fi

if [[ "${DO_POWER}" == "1" ]]; then
    echo "[STEP] PrimePower workload power"
    module purge || true
    module load ppwr/2019.03
    module load lc/2019.03

    TAGS="${TAGS}" FORCE="${FORCE}" \
    "${SIM_DIR}/run_energy_primepower_all_cleanfreq_swapaw.sh" \
      | tee "${SIM_DIR}/run_energy_primepower_all_cleanfreq_swapaw.log"
fi

if [[ "${DO_COLLECT}" == "1" ]]; then
    echo "[STEP] Collect energy summary"
    "${SIM_DIR}/collect_energy_summary_cleanfreq_swapaw.sh" \
      | tee "${SIM_DIR}/collect_energy_summary_cleanfreq_swapaw.log"
fi

if [[ "${DO_TRENDS}" == "1" ]]; then
    echo "[STEP] Extract sparsity trend tables"
    cd "${PROJ_ROOT}"
    python3 extract_sparsity_trends.py \
      --input results/energy_workloads_swapaw/energy_summary.tsv \
      --outdir results/energy_workloads_swapaw/trend_tables
    cd "${SIM_DIR}"
fi

if [[ "${DO_PLOT}" == "1" ]]; then
    echo "[STEP] Plot sparsity evidence figures"
    cd "${PROJ_ROOT}"
    python3 plot_sparsity_evidence.py \
      --indir results/energy_workloads_swapaw/trend_tables \
      --outdir results/energy_workloads_swapaw/sparsity_figures \
      --main-design top_hier \
      --baseline-design abl_mult
    cd "${SIM_DIR}"
fi

echo "[DONE] SWAP-AW energy full flow finished."
