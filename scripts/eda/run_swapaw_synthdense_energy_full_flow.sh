#!/usr/bin/env bash
# ==============================================================================
# File    : run_swapaw_synthdense_energy_full_flow.sh
# Purpose : One-command SWAP-A/W + synthetic-dense controlled sparsity energy flow.
#
# DATA_SOURCE_MODE default = 1:
#   0 = MNIST rows for all sparsity points
#   1 = synthetic dense non-zero rows for all sparsity points
#   2 = hybrid: MNIST at A=0,W=0; synthetic dense for A>0 or W>0
#
# Outputs are isolated from real-MNIST swapaw:
#   sim/energy_runs_swapaw_synthdense/
#   sim/energy_sweep_logs_swapaw_synthdense/
#   pt/power_workloads_swapaw_synthdense/
#   results/energy_workloads_swapaw_synthdense/
# ============================================================================== 

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
PT_DIR=${PT_DIR:-"${PROJ_ROOT}/pt"}

TAGS=${TAGS:-"tt_0p90v_0p90v_25c_hier abl_mf_tt0p9v25c abl_mult_tt0p9v25c abl_dec_tt0p9v25c"}
DESIGNS=${DESIGNS:-"top_hier mf mult dec"}
REGIMES=${REGIMES:-"p16_l1 p16_l2 p8_l1"}
A_SPARSITIES=${A_SPARSITIES:-"0 25 50 75 90"}
W_SPARSITIES=${W_SPARSITIES:-"0 25 50 75 90"}
MAX_OPS=${MAX_OPS:-8}
SEED=${SEED:-1}
DATA_SOURCE_MODE=${DATA_SOURCE_MODE:-1}

RUN_ROOT=${RUN_ROOT:-"${SIM_DIR}/energy_runs_swapaw_synthdense"}
LOG_DIR=${LOG_DIR:-"${SIM_DIR}/energy_sweep_logs_swapaw_synthdense"}
POWER_WORKLOADS_DIR=${POWER_WORKLOADS_DIR:-"${PT_DIR}/power_workloads_swapaw_synthdense"}
RESULT_ROOT=${RESULT_ROOT:-"${PROJ_ROOT}/results/energy_workloads_swapaw_synthdense"}

DO_GLS=${DO_GLS:-1}
DO_SAIF=${DO_SAIF:-1}
DO_POWER=${DO_POWER:-1}
DO_COLLECT=${DO_COLLECT:-1}
DO_TRENDS=${DO_TRENDS:-1}
DO_PLOT=${DO_PLOT:-1}
FORCE=${FORCE:-0}

cd "${SIM_DIR}"

mkdir -p "${RUN_ROOT}" "${LOG_DIR}" "${POWER_WORKLOADS_DIR}" "${RESULT_ROOT}"

echo "======================================================================"
echo " [SWAP-AW SYNTH-DENSE ENERGY FULL FLOW]"
echo "======================================================================"
echo "  PROJ_ROOT           : ${PROJ_ROOT}"
echo "  SIM_DIR             : ${SIM_DIR}"
echo "  TAGS                : ${TAGS}"
echo "  DESIGNS             : ${DESIGNS}"
echo "  REGIMES             : ${REGIMES}"
echo "  A_SPARSITIES        : ${A_SPARSITIES}"
echo "  W_SPARSITIES        : ${W_SPARSITIES}"
echo "  MAX_OPS             : ${MAX_OPS}"
echo "  SEED                : ${SEED}"
echo "  DATA_SOURCE_MODE    : ${DATA_SOURCE_MODE} (0=MNIST,1=SYNTH_DENSE,2=HYBRID)"
echo "  RUN_ROOT            : ${RUN_ROOT}"
echo "  LOG_DIR             : ${LOG_DIR}"
echo "  POWER_WORKLOADS_DIR : ${POWER_WORKLOADS_DIR}"
echo "  RESULT_ROOT         : ${RESULT_ROOT}"
echo "  FORCE               : ${FORCE}"
echo "  DO_GLS              : ${DO_GLS}"
echo "  DO_SAIF             : ${DO_SAIF}"
echo "  DO_POWER            : ${DO_POWER}"
echo "  DO_COLLECT          : ${DO_COLLECT}"
echo "  DO_TRENDS           : ${DO_TRENDS}"
echo "  DO_PLOT             : ${DO_PLOT}"
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
    DATA_SOURCE_MODE="${DATA_SOURCE_MODE}" \
    LOG_DIR="${LOG_DIR}" \
    "${SIM_DIR}/run_energy_mnist_sparse_sweep_cleanfreq_swapaw_synthdense.sh" \
      | tee "${SIM_DIR}/run_energy_mnist_sparse_sweep_cleanfreq_swapaw_synthdense.log"
fi

if [[ "${DO_SAIF}" == "1" ]]; then
    echo "[STEP] VCD -> SAIF"
    module purge || true
    module load vcs/2022.06-SP2

    TAGS="${TAGS}" FORCE="${FORCE}" ENERGY_RUNS_DIR="${RUN_ROOT}" \
    "${SIM_DIR}/run_energy_vcd2saif_all_swapaw.sh" \
      | tee "${SIM_DIR}/run_energy_vcd2saif_all_swapaw_synthdense.log"
fi

if [[ "${DO_POWER}" == "1" ]]; then
    echo "[STEP] PrimePower workload power"
    module purge || true
    module load ppwr/2019.03
    module load lc/2019.03

    TAGS="${TAGS}" FORCE="${FORCE}" ENERGY_RUNS_DIR="${RUN_ROOT}" POWER_WORKLOADS_DIR="${POWER_WORKLOADS_DIR}" \
    "${SIM_DIR}/run_energy_primepower_all_cleanfreq_swapaw.sh" \
      | tee "${SIM_DIR}/run_energy_primepower_all_cleanfreq_swapaw_synthdense.log"
fi

if [[ "${DO_COLLECT}" == "1" ]]; then
    echo "[STEP] Collect energy summary"
    ENERGY_RUNS_DIR="${RUN_ROOT}" POWER_WORKLOADS_DIR="${POWER_WORKLOADS_DIR}" OUT_DIR="${RESULT_ROOT}" \
    "${SIM_DIR}/collect_energy_summary_cleanfreq_swapaw.sh" \
      | tee "${SIM_DIR}/collect_energy_summary_cleanfreq_swapaw_synthdense.log"
fi

if [[ "${DO_TRENDS}" == "1" ]]; then
    echo "[STEP] Extract sparsity trend tables"
    cd "${PROJ_ROOT}"
    python3 extract_sparsity_trends.py \
      --input results/energy_workloads_swapaw_synthdense/energy_summary.tsv \
      --outdir results/energy_workloads_swapaw_synthdense/trend_tables
    cd "${SIM_DIR}"
fi

if [[ "${DO_PLOT}" == "1" ]]; then
    echo "[STEP] Plot sparsity evidence figures"
    cd "${PROJ_ROOT}"
    python3 plot_sparsity_evidence.py \
      --indir results/energy_workloads_swapaw_synthdense/trend_tables \
      --outdir results/energy_workloads_swapaw_synthdense/sparsity_figures \
      --main-design top_hier \
      --baseline-design abl_mult
    cd "${SIM_DIR}"
fi

echo "[DONE] SWAP-AW SYNTH-DENSE energy full flow finished."
