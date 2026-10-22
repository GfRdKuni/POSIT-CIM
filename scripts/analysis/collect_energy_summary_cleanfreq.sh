#!/usr/bin/env bash
# ==============================================================================
# File    : collect_energy_summary_cleanfreq.sh
# Purpose : Merge perf.csv and PrimePower power_total.rpt into energy_summary.tsv,
#           using per-run clk_period_ns from run_info.tsv if available.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/collect_energy_summary_cleanfreq.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   ./collect_energy_summary_cleanfreq.sh
#
# Output:
#   ../results/energy_workloads/energy_summary_cleanfreq.tsv
#   ../results/energy_workloads/energy_missing_power_cleanfreq.tsv
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
OUT_DIR="${PROJ_ROOT}/results/energy_workloads"
PERIOD_CFG=${PERIOD_CFG:-"${SIM_DIR}/energy_tb/configs/clean_periods.tsv"}
DEFAULT_CLK_PERIOD_NS=${DEFAULT_CLK_PERIOD_NS:-"1.08"}

mkdir -p "${OUT_DIR}"

OUT="${OUT_DIR}/energy_summary_cleanfreq.tsv"
MISS="${OUT_DIR}/energy_missing_power_cleanfreq.tsv"

cd "${SIM_DIR}"

parse_power_w() {
    local rpt="$1"
    awk '
    BEGIN {
        scale=1.0;
        power="NA";
    }
    /Power Unit/ {
        if ($0 ~ /1pW/) scale=1e-12;
        else if ($0 ~ /1nW/) scale=1e-9;
        else if ($0 ~ /1uW/) scale=1e-6;
        else if ($0 ~ /1mW/) scale=1e-3;
        else if ($0 ~ /1W/) scale=1.0;
    }
    /^[[:space:]]*Total[[:space:]]/ || /Total Power/ {
        val="";
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) {
                val=$i;
            }
        }
        if (val != "") power=val*scale;
    }
    END { print power; }' "${rpt}"
}

period_from_cfg_by_tag() {
    local tag="$1"
    if [[ -f "${PERIOD_CFG}" ]]; then
        awk -F'\t' -v t="${tag}" '
            /^[[:space:]]*#/ { next }
            NF < 4 { next }
            $2 == t { print $4; found=1; exit }
            END { if (!found) exit 2 }
        ' "${PERIOD_CFG}" || true
    fi
}

period_for_run() {
    local tag="$1"
    local run_dir="$2"
    local info="${run_dir}/run_info.tsv"

    if [[ -f "${info}" ]]; then
        # header:
        # key tag design_name netlist_top workload a_sparsity_pct w_sparsity_pct seed max_ops clk_period_ns run_name
        awk -F'\t' 'NR==2 { print $10; exit }' "${info}"
        return 0
    fi

    local p
    p=$(period_from_cfg_by_tag "${tag}")
    if [[ -n "${p}" ]]; then
        echo "${p}"
        return 0
    fi

    echo "${DEFAULT_CLK_PERIOD_NS}"
}

echo -e "tag\trun_name\tclk_period_ns\tdesign_key\tdut\tworkload\tregime\ta_sparsity_pct\tw_sparsity_pct\tseed\top_idx\tmode\tbatch_cnt\tstart_addr\tcycles\tbusy_cycles\tdense_macs\teffective_macs\tdense_ops\teffective_ops\tresult_hex\tstatus\tpower_w\truntime_ns\tenergy_j\tdense_tops\teffective_tops\tdense_tops_per_w\teffective_tops_per_w\tdense_pj_per_op\teffective_pj_per_op" > "${OUT}"
echo -e "tag\trun_name\treason\tpath" > "${MISS}"

count=0
missing=0

while IFS= read -r perf; do
    # energy_runs/<tag>/<run_name>/perf.csv
    tag=$(echo "${perf}" | awk -F'/' '{print $2}')
    run_name=$(echo "${perf}" | awk -F'/' '{print $3}')
    run_dir=$(dirname "${perf}")

    rpt="${PROJ_ROOT}/pt/power_workloads/${tag}/${run_name}/power_total.rpt"
    clk_ns=$(period_for_run "${tag}" "${run_dir}")

    if [[ ! -f "${rpt}" ]]; then
        echo -e "${tag}\t${run_name}\tmissing_power\t${rpt}" >> "${MISS}"
        missing=$((missing + 1))
        continue
    fi

    power_w=$(parse_power_w "${rpt}")

    if [[ "${power_w}" == "NA" || -z "${power_w}" ]]; then
        echo -e "${tag}\t${run_name}\tparse_power_failed\t${rpt}" >> "${MISS}"
        missing=$((missing + 1))
        continue
    fi

    tail -n +2 "${perf}" | while IFS=',' read -r design_key dut workload a_sp w_sp seed op_idx mode batch_cnt start_addr cycles busy_cycles dense_macs effective_macs dense_ops effective_ops result_hex status; do
        [[ -z "${design_key}" ]] && continue

        awk -v tag="${tag}" \
            -v run_name="${run_name}" \
            -v clk_ns="${clk_ns}" \
            -v design_key="${design_key}" \
            -v dut="${dut}" \
            -v workload="${workload}" \
            -v a_sp="${a_sp}" \
            -v w_sp="${w_sp}" \
            -v seed="${seed}" \
            -v op_idx="${op_idx}" \
            -v mode="${mode}" \
            -v batch_cnt="${batch_cnt}" \
            -v start_addr="${start_addr}" \
            -v cycles="${cycles}" \
            -v busy_cycles="${busy_cycles}" \
            -v dense_macs="${dense_macs}" \
            -v effective_macs="${effective_macs}" \
            -v dense_ops="${dense_ops}" \
            -v effective_ops="${effective_ops}" \
            -v result_hex="${result_hex}" \
            -v status="${status}" \
            -v power_w="${power_w}" \
            'BEGIN {
                runtime_ns = cycles * clk_ns;
                runtime_s  = runtime_ns * 1e-9;
                energy_j   = power_w * runtime_s;

                dense_tops = (dense_ops > 0 && runtime_s > 0) ? dense_ops / runtime_s / 1e12 : 0;
                eff_tops   = (effective_ops > 0 && runtime_s > 0) ? effective_ops / runtime_s / 1e12 : 0;

                dense_tops_per_w = (power_w > 0) ? dense_tops / power_w : 0;
                eff_tops_per_w   = (power_w > 0) ? eff_tops / power_w : 0;

                dense_pj_per_op = (dense_ops > 0) ? energy_j / dense_ops * 1e12 : 0;
                eff_pj_per_op   = (effective_ops > 0) ? energy_j / effective_ops * 1e12 : 0;

                regime=workload;
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\n", \
                    tag, run_name, clk_ns, design_key, dut, workload, regime, a_sp, w_sp, seed, op_idx, mode, batch_cnt, start_addr, cycles, busy_cycles, dense_macs, effective_macs, dense_ops, effective_ops, result_hex, status, power_w, runtime_ns, energy_j, dense_tops, eff_tops, dense_tops_per_w, eff_tops_per_w, dense_pj_per_op, eff_pj_per_op;
            }' >> "${OUT}"
    done

    count=$((count + 1))

done < <(find energy_runs -name perf.csv | sort)

echo "[DONE] Wrote:"
echo "  ${OUT}"
echo "  ${MISS}"
echo
echo "perf.csv with power: ${count}"
echo "missing/failed power: ${missing}"
echo
echo "Preview:"
head -5 "${OUT}" | column -t -s $'\t' || true
