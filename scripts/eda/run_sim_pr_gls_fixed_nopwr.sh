#!/usr/bin/env bash
# ==============================================================================
# File    : run_sim_pr_gls.sh
# Project : posit_cim_28nm
# Purpose : Post-route SDF GLS runner for Innovus-routed cim_top / ablations.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/run_sim_pr_gls.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x run_sim_pr_gls.sh
#
#   # Run all three ablations from Innovus outputs:
#   ilaunch ./run_sim_pr_gls.sh ablation tt0p9v25c
#
#   # Run only one ablation:
#   ilaunch ./run_sim_pr_gls.sh dec tt0p9v25c
#   ilaunch ./run_sim_pr_gls.sh mf tt0p9v25c
#   ilaunch ./run_sim_pr_gls.sh mult tt0p9v25c
#
#   # Run original cim_top hierarchical post-route result:
#   ilaunch ./run_sim_pr_gls.sh top_hier
#
# Notes:
#   1. This script does NOT call ilaunch internally.
#   2. It reads Innovus post-route outputs under pnr/runs_*/outputs/.
#   3. tb_cim_top.v already supports DUT_TOP, SDF_PATH and VCD_PATH.
#   4. +no_notifier is intentionally enabled to prevent small timing-check
#      violations from corrupting functional GLS with X propagation.  Timing
#      signoff should be judged by Innovus/PT reports, not notifier-induced Xs.
#   5. IMPORTANT: this script filters out *_pwr.v standard-cell models.
#      The Innovus routed netlist used here is non-PG for simulation, so
#      power-aware models would leave VDD/VSS unconnected and produce Xs.
# ==============================================================================

set -u
set -o pipefail

MODE=${1:-"ablation"}          # ablation | dec | mf | mult | top_hier | top | custom
CORNER_ID=${2:-"tt0p9v25c"}

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
PNR_DIR=${PNR_DIR:-"${PROJ_ROOT}/pnr"}

VCS_BIN=${VCS_BIN:-"vcs"}
VCS_COMMON_OPTS=${VCS_COMMON_OPTS:-"-full64 -sverilog +v2k -q -timescale=1ns/1ps"}

CLK_PERIOD_NS=${CLK_PERIOD_NS:-"2.8"}
ENABLE_MNIST=${ENABLE_MNIST:-1}

STD_VERILOG_ROOT=${STD_VERILOG_ROOT:-"/path/to/licensed_pdk/tsmcN28/TSMCHOME/digital/Front_End/verilog"}

# The top hierarchical P&R tag from our Innovus ablation driver.
TOP_HIER_TAG=${TOP_HIER_TAG:-"tt_0p90v_0p90v_25c_hier"}

cd "${SIM_DIR}" || { echo "[FATAL] Cannot cd to ${SIM_DIR}" >&2; exit 1; }

if [[ "${ENABLE_MNIST}" == "1" ]]; then
    if ! ls "${SIM_DIR}/testdata"/*.hex >/dev/null 2>&1; then
        echo "[FATAL] ENABLE_MNIST=1 but no hex files found under ${SIM_DIR}/testdata" >&2
        exit 1
    fi
fi

build_defines() {
    local dut_top="$1"
    local defs=()
    defs+=("+define+POST_SYN")
    defs+=("+define+POST_ROUTE")
    defs+=("+define+CLK_PERIOD=${CLK_PERIOD_NS}")
    defs+=("+define+TB_FATAL_ON_FAIL")
    defs+=("+define+HAVE_REAL_RF_WRAPPER")
    defs+=("+define+DUT_TOP=${dut_top}")
    if [[ "${ENABLE_MNIST}" == "1" ]]; then
        defs+=("+define+MNIST_REAL_DATA")
    fi
    printf "%s\n" "${defs[@]}"
}

std_cell_args() {
    local files=()

    if [[ -n "${STD_CELL_V_LIST:-}" ]]; then
        # User override, space-separated.
        # shellcheck disable=SC2206
        files=( ${STD_CELL_V_LIST} )
    else
        while IFS= read -r f; do
            files+=("${f}")
        done < <(
            find "${STD_VERILOG_ROOT}" -maxdepth 3 -type f \
                -path "*tcbn28hpcplusbwp30p140*" \
                -name "tcbn28hpcplusbwp30p140*.v" \
                ! -name "*_pwr.v" \
                ! -name "*_cdl.v" \
                ! -name "*_lvs.v" 2>/dev/null | sort -u
        )
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "[FATAL] No std-cell Verilog models found under ${STD_VERILOG_ROOT}" >&2
        echo "        You may set STD_CELL_V_LIST manually." >&2
        exit 1
    fi

    local filtered=()
    local f
    for f in "${files[@]}"; do
        # For plain functional GLS, do NOT use power-aware *_pwr.v models unless
        # the netlist explicitly contains and connects VDD/VSS pins.  Our Innovus
        # saveNetlist output is non-PG for simulation, so *_pwr.v would leave
        # power pins unconnected and drive cell outputs to X.
        case "$(basename "${f}")" in
            *_pwr.v|*_cdl.v|*_lvs.v)
                echo "[INFO] Skip power/LVS std-cell model for GLS: ${f}" >&2
                continue
                ;;
        esac
        filtered+=("${f}")
    done

    if [[ ${#filtered[@]} -eq 0 ]]; then
        echo "[FATAL] No non-power std-cell Verilog models remain after filtering." >&2
        echo "        Do not use *_pwr.v for this non-PG routed netlist GLS." >&2
        exit 1
    fi

    for f in "${filtered[@]}"; do
        if [[ ! -f "${f}" ]]; then
            echo "[FATAL] Missing std-cell Verilog model: ${f}" >&2
            exit 1
        fi
        echo "-v"
        echo "${f}"
    done
}

dw_args() {
    local candidates=()

    if [[ -n "${SYNOPSYS:-}" ]]; then
        candidates+=("${SYNOPSYS}/dw/sim_ver")
    fi
    candidates+=("/path/to/eda_tools/synopsys/syn-2019.03/dw/sim_ver")
    candidates+=("/path/to/eda_tools/synopsys/syn-2019.03/libraries/syn")
    candidates+=("/tools/eda/synopsys/syn/T-2022.03-SP5-3/dw/sim_ver")

    local d
    for d in "${candidates[@]}"; do
        if [[ -d "${d}" ]]; then
            echo "-y"
            echo "${d}"
            echo "+libext+.v"
            return 0
        fi
    done

    echo "[WARN] No DesignWare simulation directory found; continuing without -y DW dir." >&2
    return 0
}

# Arguments:
#   label tb_file tb_top dut_top netlist_top run_tag
# File convention:
#   pnr/runs_${run_tag}/outputs/${netlist_top}_${run_tag}_routed.v
#   pnr/runs_${run_tag}/outputs/${netlist_top}_${run_tag}_routed.sdf
run_one_pr_gls() {
    local label="$1"
    local tb_file="$2"
    local tb_top="$3"
    local dut_top="$4"
    local netlist_top="$5"
    local run_tag="$6"

    local out_dir="${PNR_DIR}/runs_${run_tag}/outputs"
    local netlist="${out_dir}/${netlist_top}_${run_tag}_routed.v"
    local sdf="${out_dir}/${netlist_top}_${run_tag}_routed.sdf"

    if [[ ! -f "${netlist}" ]]; then
        echo "[SKIP] ${label}: missing post-route netlist ${netlist}"
        return 2
    fi
    if [[ ! -f "${sdf}" ]]; then
        echo "[SKIP] ${label}: missing post-route SDF ${sdf}"
        return 2
    fi
    if [[ ! -f "${tb_file}" ]]; then
        echo "[FAIL] ${label}: missing TB ${tb_file}" >&2
        return 1
    fi

    local work="${SIM_DIR}/sim_workspace_pr_gls_${run_tag}"
    mkdir -p "${work}"

    local simv="${work}/simv_${run_tag}"
    local clog="${work}/vcs_compile_${run_tag}.log"
    local rlog="${work}/vcs_run_${run_tag}.log"
    local csrc="${work}/csrc_${run_tag}"
    local vcd="${work}/${tb_top}_${run_tag}_postroute.vcd"

    mapfile -t DEFINES < <(build_defines "${dut_top}")
    mapfile -t STD_ARGS < <(std_cell_args)
    mapfile -t DW_ARGS  < <(dw_args)

    echo ""
    echo "======================================================================"
    echo " [POST-ROUTE GLS] ${label}"
    echo "======================================================================"
    echo "  RUN_TAG     : ${run_tag}"
    echo "  TB          : ${tb_file}"
    echo "  TB_TOP      : ${tb_top}"
    echo "  DUT_TOP     : ${dut_top}"
    echo "  NETLIST_TOP : ${netlist_top}"
    echo "  NETLIST     : ${netlist}"
    echo "  SDF         : ${sdf}"
    echo "  VCD         : ${vcd}"
    echo "  WORK        : ${work}"
    echo "======================================================================"

    "${VCS_BIN}" ${VCS_COMMON_OPTS} \
        +neg_tchk +negdelay +no_notifier \
        "${DEFINES[@]}" \
        "+define+SDF_PATH=\"${sdf}\"" \
        "+define+VCD_PATH=\"${vcd}\"" \
        "${tb_file}" "${netlist}" \
        "${STD_ARGS[@]}" \
        "${DW_ARGS[@]}" \
        -top "${tb_top}" \
        -Mdir="${csrc}" \
        -l "${clog}" \
        -o "${simv}"

    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        echo "[FAIL] ${label}: VCS compile failed, see ${clog}"
        return 1
    fi

    "${simv}" -l "${rlog}" -q
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        echo "[FAIL] ${label}: simulation exited with ${rc}, see ${rlog}"
        return 1
    fi

    grep -E "SDF Annotation|Doing SDF annotation|\[TB\] OVERALL:" "${rlog}" || true

    if grep -q "\[TB\] OVERALL: PASS" "${rlog}"; then
        echo "[OK] ${label}: post-route GLS PASS"
        return 0
    else
        echo "[FAIL] ${label}: post-route GLS did not report OVERALL PASS, see ${rlog}"
        return 1
    fi
}

accumulate() {
    local rc="$1"
    if [[ ${rc} -eq 0 ]]; then
        pass=$((pass + 1))
    elif [[ ${rc} -eq 2 ]]; then
        skip=$((skip + 1))
    else
        fail=$((fail + 1))
    fi
}

run_abl_one() {
    local abl="$1"
    local top="cim_top_abl_${abl}"
    local tag="abl_${abl}_${CORNER_ID}"
    run_one_pr_gls "${top} post-route ${CORNER_ID}" \
        "${SIM_DIR}/tb_cim_top.v" "tb_cim_top" "${top}" "${top}" "${tag}"
}

run_top_hier_one() {
    local tag="${TOP_HIER_TAG}"
    run_one_pr_gls "cim_top post-route ${tag}" \
        "${SIM_DIR}/tb_cim_top.v" "tb_cim_top" "cim_top" "cim_top" "${tag}"
}

pass=0
fail=0
skip=0

case "${MODE}" in
    ablation)
        for abl in mult mf dec; do
            run_abl_one "${abl}"
            accumulate "$?"
        done
        ;;

    dec|mf|mult)
        run_abl_one "${MODE}"
        accumulate "$?"
        ;;

    top|top_hier)
        run_top_hier_one
        accumulate "$?"
        ;;

    custom)
        : "${TB_FILE:?MODE=custom requires TB_FILE}"
        : "${TB_TOP:?MODE=custom requires TB_TOP}"
        : "${DUT_TOP:?MODE=custom requires DUT_TOP}"
        : "${NETLIST_TOP:?MODE=custom requires NETLIST_TOP}"
        : "${RUN_TAG:?MODE=custom requires RUN_TAG, e.g. abl_dec_tt0p9v25c}"
        run_one_pr_gls "custom post-route ${RUN_TAG}" \
            "${TB_FILE}" "${TB_TOP}" "${DUT_TOP}" "${NETLIST_TOP}" "${RUN_TAG}"
        accumulate "$?"
        ;;

    *)
        echo "[FATAL] Unknown MODE='${MODE}'. Use ablation|dec|mf|mult|top_hier|custom." >&2
        exit 1
        ;;
esac

echo ""
echo "======================================================================"
echo " POST-ROUTE GLS SUMMARY"
echo "======================================================================"
echo " PASS : ${pass}"
echo " FAIL : ${fail}"
echo " SKIP : ${skip}"
echo "======================================================================"

if [[ ${fail} -ne 0 ]]; then
    exit 1
fi
exit 0
