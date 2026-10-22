#!/usr/bin/env bash
# ==============================================================================
# File    : collect_energy_summary.sh
# Purpose : Merge perf.csv and PrimePower power_total.rpt into energy_summary.tsv.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/sim/collect_energy_summary.sh
#
# Usage:
#   cd /path/to/projects/posit_cim_28nm/sim
#   chmod +x collect_energy_summary.sh
#   ./collect_energy_summary.sh
#
# Output:
#   ../results/energy_workloads/energy_summary.tsv
#   ../results/energy_workloads/energy_missing_power.tsv
# ==============================================================================

set -e
set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
SIM_DIR=${SIM_DIR:-"${PROJ_ROOT}/sim"}
OUT_DIR="${PROJ_ROOT}/results/energy_workloads"
CLK_PERIOD_NS=${CLK_PERIOD_NS:-"1.08"}

mkdir -p "${OUT_DIR}"

OUT="${OUT_DIR}/energy_summary.tsv"
MISS="${OUT_DIR}/energy_missing_power.tsv"

cd "${SIM_DIR}"

# Try to parse total power in W from a PrimePower report_power output.
# The parser handles common formats:
#   Power Unit: 1mW
#   Total ... 19.5
#   Total Power ... 0.0195
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
        # collect numeric fields; use the last numeric field on the line
        for (i=1; i<=NF; i++) {
            if ($i ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) {
                val=$i;
            }
        }
        if (val != "") {
            power=val*scale;
        }
    }
    END {
        print power;
    }' "${rpt}"
}

echo -e "tag\trun_name\tdesign_key\tdut\tworkload\tregime\ta_sparsity_pct\tw_sparsity_pct\tseed\top_idx\tmode\tbatch_cnt\tstart_addr\tcycles\tbusy_cycles\tdense_macs\teffective_macs\tdense_ops\teffective_ops\tresult_hex\tstatus\tpower_w\truntime_ns\tenergy_j\tdense_tops\teffective_tops\tdense_tops_per_w\teffective_tops_per_w\tdense_pj_per_op\teffective_pj_per_op" > "${OUT}"

echo -e "tag\trun_name\tpower_rpt" > "${MISS}"

count=0
missing=0

while IFS= read -r perf; do
    # energy_runs/<tag>/<run_name>/perf.csv
    tag=$(echo "${perf}" | awk -F'/' '{print $2}')
    run_name=$(echo "${perf}" | awk -F'/' '{print $3}')

    rpt="${PROJ_ROOT}/pt/power_workloads/${tag}/${run_name}/power_total.rpt"

    if [[ ! -f "${rpt}" ]]; then
        echo -e "${tag}\t${run_name}\t${rpt}" >> "${MISS}"
        missing=$((missing + 1))
        continue
    fi

    power_w=$(parse_power_w "${rpt}")

    if [[ "${power_w}" == "NA" || -z "${power_w}" ]]; then
        echo -e "${tag}\t${run_name}\t${rpt}" >> "${MISS}"
        missing=$((missing + 1))
        continue
    fi

    tail -n +2 "${perf}" | while IFS=',' read -r design_key dut workload a_sp w_sp seed op_idx mode batch_cnt start_addr cycles busy_cycles dense_macs effective_macs dense_ops effective_ops result_hex status; do
        [[ -z "${design_key}" ]] && continue

        awk -v tag="${tag}" \
            -v run_name="${run_name}" \
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
            -v clk_ns="${CLK_PERIOD_NS}" \
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
                # workload is p16_l1/p16_l2/p8_l1 in perf.csv; run_name has sparsity.
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\t%.12g\n", \
                    tag, run_name, design_key, dut, workload, regime, a_sp, w_sp, seed, op_idx, mode, batch_cnt, start_addr, cycles, busy_cycles, dense_macs, effective_macs, dense_ops, effective_ops, result_hex, status, power_w, runtime_ns, energy_j, dense_tops, eff_tops, dense_tops_per_w, eff_tops_per_w, dense_pj_per_op, eff_pj_per_op;
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
