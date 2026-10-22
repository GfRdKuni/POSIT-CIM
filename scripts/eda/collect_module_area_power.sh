#!/usr/bin/env bash
# ==============================================================================
# File    : collect_module_area_power.sh
# Project : posit_cim_28nm
# Purpose : Collect module-level area from DC and PNR reports, plus current
#           power/timing summary. Pure bash/awk/grep/sed. No Python.
#
# Main outputs:
#   results/current_area_power_summary/SUMMARY.tsv
#   results/module_area_summary/module_area_dc.tsv
#   results/module_area_summary/module_area_pnr.tsv
#   results/module_area_summary/module_area_top_dc.tsv
#   results/module_area_summary/module_area_top_pnr.tsv
#
# Important fixes:
#   1. Power is collected ONLY from:
#        pt/runs_${tag}_power/reports_pwr_session_*ns/power_total.rpt
#      It will NOT collect workload power under:
#        pt/power_workloads/${tag}/...
#
#   2. holdfix tags are supported:
#        *_holdfix
#      For holdfix cases, DC area is taken from the corresponding pre-ECO
#      synthesis report because hold ECO does not rerun DC.
# ==============================================================================

set -u
set -o pipefail

PROJ_ROOT=${PROJ_ROOT:-"/path/to/projects/posit_cim_28nm"}
RESULT_ROOT="${PROJ_ROOT}/results/current_area_power_summary"
MODULE_ROOT="${PROJ_ROOT}/results/module_area_summary"

rm -rf "${RESULT_ROOT}" "${MODULE_ROOT}"
mkdir -p "${RESULT_ROOT}" "${MODULE_ROOT}"

SUMMARY_TSV="${RESULT_ROOT}/SUMMARY.tsv"
DC_ALL_TSV="${MODULE_ROOT}/module_area_dc.tsv"
PNR_ALL_TSV="${MODULE_ROOT}/module_area_pnr.tsv"
DC_TOP_TSV="${MODULE_ROOT}/module_area_top_dc.tsv"
PNR_TOP_TSV="${MODULE_ROOT}/module_area_top_pnr.tsv"

echo -e "key\tdesign_name\ttag\tdc_total_area\tpnr_total_area\tpower_w\tworst_setup_wns\tworst_hold_wns\tstatus" > "${SUMMARY_TSV}"
echo -e "key\tdesign_name\ttag\thier_cell\tdepth\tarea\tpercent\tcomb_area\tnoncomb_area\tblackbox_area\tmodule" > "${DC_ALL_TSV}"
echo -e "key\tdesign_name\ttag\thinst\tdepth\tmodule\tinst_count\ttotal_area" > "${PNR_ALL_TSV}"
echo -e "key\tdesign_name\ttag\thier_cell\tarea\tpercent\tmodule" > "${DC_TOP_TSV}"
echo -e "key\tdesign_name\ttag\thinst\tmodule\tinst_count\ttotal_area" > "${PNR_TOP_TSV}"

is_holdfix_tag() {
  local tag="$1"
  [[ "$tag" == *_holdfix ]]
}

base_tag_of() {
  local tag="$1"
  echo "${tag%_holdfix}"
}

syn_tag_of() {
  local tag="$1"
  # holdfix does not have a new DC synthesis result; reuse the base synthesis tag.
  if is_holdfix_tag "$tag"; then
    base_tag_of "$tag"
  else
    echo "$tag"
  fi
}

guess_design_name() {
  local tag="$1"
  local base
  base="$(base_tag_of "$tag")"

  case "$base" in
    abl_mf_tt0p9v25c) echo "cim_top_abl_mf" ;;
    abl_mult_tt0p9v25c) echo "cim_top_abl_mult" ;;
    abl_dec_tt0p9v25c) echo "cim_top_abl_dec" ;;
    tt_0p90v_0p90v_25c_hier) echo "cim_top" ;;
    chip_tt0p9v25c) echo "cim_chip" ;;
    *) echo "UNKNOWN" ;;
  esac
}

guess_key() {
  local tag="$1"
  local suffix=""
  local base

  if is_holdfix_tag "$tag"; then
    suffix="_holdfix"
    base="$(base_tag_of "$tag")"
  else
    base="$tag"
  fi

  case "$base" in
    abl_mf_tt0p9v25c) echo "abl_mf${suffix}" ;;
    abl_mult_tt0p9v25c) echo "abl_mult${suffix}" ;;
    abl_dec_tt0p9v25c) echo "abl_dec${suffix}" ;;
    tt_0p90v_0p90v_25c_hier) echo "top_hier${suffix}" ;;
    chip_tt0p9v25c) echo "chip${suffix}" ;;
    *) echo "$tag" ;;
  esac
}

is_known_tag() {
  local tag="$1"
  case "$tag" in
    abl_dec_tt0p9v25c|abl_mf_tt0p9v25c|abl_mult_tt0p9v25c|tt_0p90v_0p90v_25c_hier|chip_tt0p9v25c)
      return 0 ;;
    abl_dec_tt0p9v25c_holdfix|abl_mf_tt0p9v25c_holdfix|abl_mult_tt0p9v25c_holdfix|tt_0p90v_0p90v_25c_hier_holdfix|chip_tt0p9v25c_holdfix)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

find_dc_area_report() {
  local tag="$1"
  local syn_tag
  local rpt_dir

  syn_tag="$(syn_tag_of "$tag")"
  rpt_dir="${PROJ_ROOT}/syn/reports_${syn_tag}"

  # Prefer reports containing "Hierarchical area distribution".
  if [[ -d "$rpt_dir" ]]; then
    while IFS= read -r f; do
      if grep -q "Hierarchical area distribution" "$f" 2>/dev/null; then
        echo "$f"
        return
      fi
    done < <(find "$rpt_dir" -maxdepth 1 -type f \( -iname "*area*.rpt" -o -iname "*hier*.rpt" -o -iname "*qor*.rpt" \) | sort)
  fi

  # Fallback: search whole syn tree under synthesis tag, not holdfix tag.
  while IFS= read -r f; do
    if grep -q "Hierarchical area distribution" "$f" 2>/dev/null; then
      echo "$f"
      return
    fi
  done < <(find "${PROJ_ROOT}/syn" -path "*${syn_tag}*" -type f \( -iname "*area*.rpt" -o -iname "*hier*.rpt" -o -iname "*qor*.rpt" \) 2>/dev/null | sort)

  # Last fallback: any area report.
  find "${PROJ_ROOT}/syn" -path "*${syn_tag}*" -type f -iname "*area*.rpt" 2>/dev/null | sort | head -1
}

find_pnr_area_report() {
  local tag="$1"
  local rpt_dir="${PROJ_ROOT}/pnr/runs_${tag}/reports"

  # Prefer reports containing PNR hierarchy table header.
  if [[ -d "$rpt_dir" ]]; then
    while IFS= read -r f; do
      if grep -q "Hinst Name" "$f" 2>/dev/null && grep -q "Total Area" "$f" 2>/dev/null; then
        echo "$f"
        return
      fi
    done < <(find "$rpt_dir" -type f \( -iname "*area*.rpt" -o -iname "*summary*.rpt" -o -iname "*qor*.rpt" -o -iname "*.rpt" \) | sort)
  fi

  find "${PROJ_ROOT}/pnr/runs_${tag}/reports" -type f -iname "*area*.rpt" 2>/dev/null | sort | head -1
}

find_allrc_summary() {
  local tag="$1"
  local rpt

  rpt="${PROJ_ROOT}/pt/runs_${tag}_allrc_sta/allrc_wns_summary.rpt"
  if [[ -f "$rpt" ]]; then
    echo "$rpt"
    return
  fi

  # Fallback only within the strict runs_${tag}_allrc_sta directory.
  find "${PROJ_ROOT}/pt/runs_${tag}_allrc_sta" -name "allrc_wns_summary.rpt" 2>/dev/null | sort | head -1
}

find_fmax_summary() {
  local tag="$1"
  local rpt

  rpt="${PROJ_ROOT}/pt/runs_${tag}_allrc_sta/reports_fmax_preserve_sdc_summary.rpt"
  if [[ -f "$rpt" ]]; then
    echo "$rpt"
    return
  fi

  # Fallback only within the strict runs_${tag}_allrc_sta directory.
  find "${PROJ_ROOT}/pt/runs_${tag}_allrc_sta" -name "reports_fmax_preserve_sdc_summary.rpt" 2>/dev/null | sort | head -1
}

find_power_report() {
  local tag="$1"
  local power_root="${PROJ_ROOT}/pt/runs_${tag}_power"

  # IMPORTANT:
  # Only collect ordinary PPA/session power.
  # Never collect workload power under pt/power_workloads/${tag}/...
  if [[ ! -d "$power_root" ]]; then
    return 0
  fi

  # Prefer reports_pwr_session_*ns/power_total.rpt.
  find "$power_root" \
    -path "*/reports_pwr_session_*ns/power_total.rpt" \
    -type f \
    -printf "%T@ %p\n" 2>/dev/null \
    | sort -n \
    | tail -1 \
    | cut -d' ' -f2-
}

extract_power_w() {
  local rpt="$1"
  if [[ ! -f "$rpt" ]]; then
    echo "NA"
    return
  fi

  awk '
  BEGIN { val="NA"; unit="W" }
  {
    low=tolower($0)
    if (low ~ /total/ && low ~ /power/) {
      for (i=1;i<=NF;i++) {
        if ($i ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) val=$i
      }
      if (low ~ /mw/) unit="mW"
      else if (low ~ /uw/) unit="uW"
      else if (low ~ /nw/) unit="nW"
      else unit="W"
    }
  }
  END {
    if (val=="NA") print "NA";
    else if (unit=="mW") print val/1000.0;
    else if (unit=="uW") print val/1000000.0;
    else if (unit=="nW") print val/1000000000.0;
    else print val;
  }' "$rpt"
}

extract_wns_pair() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "NA|NA"
    return
  fi

  awk '
  NR>1 {
    if ($2 != "" && $2 !~ /MISSING|NO_PATH|NO_SETUP_PATH|NO_HOLD_PATH|NA/) {
      if (setup=="" || $2 < setup) setup=$2
    }
    if ($3 != "" && $3 !~ /MISSING|NO_PATH|NO_SETUP_PATH|NO_HOLD_PATH|NA/) {
      if (hold=="" || $3 < hold) hold=$3
    }
  }
  END {
    if (setup=="") setup="NA"
    if (hold=="") hold="NA"
    print setup "|" hold
  }' "$f"
}

parse_dc_area() {
  local key="$1"
  local design="$2"
  local tag="$3"
  local rpt="$4"
  local out_all="$5"
  local out_top="$6"

  [[ -f "$rpt" ]] || return 0

  awk -v key="$key" -v design="$design" -v tag="$tag" -v out_top="$out_top" '
  function depth_of(s, t) {
    t=s
    return gsub("/", "/", t)
  }
  BEGIN { in_tbl=0 }
  /Hierarchical area distribution/ { in_tbl=1; next }
  in_tbl==1 && /^[-][ -]*$/ { dash_count++; next }
  in_tbl==1 && /^Total[ \t]/ { exit }
  in_tbl==1 {
    # Skip headers and blank lines.
    if ($0 ~ /^[ \t]*$/) next
    if ($0 ~ /Global cell area/) next
    if ($0 ~ /Local cell area/) next
    if ($0 ~ /Hierarchical cell/) next
    if ($0 ~ /Absolute/) next
    if ($0 ~ /Total[ \t]+Total/) next
    if ($0 ~ /^[-]/) next

    # Handle normal DC hierarchy rows:
    # hier area percent comb noncomb blackbox module...
    #
    # Also handle continuation lines where hierarchy name is on previous line:
    # u_storage/.../u_rf_bank_high
    #                                6671.5739 13.2 ...
    line=$0

    if (line ~ /^[^ \t]/ && $2 ~ /^[-+]?[0-9]*\.?[0-9]+$/ && $3 ~ /^[-+]?[0-9]*\.?[0-9]+$/) {
      hier=$1
      area=$2
      pct=$3
      comb=$4
      noncomb=$5
      black=$6
      module=""
      for (i=7;i<=NF;i++) module = module (module=="" ? "" : " ") $i

      d=depth_of(hier)
      print key "\t" design "\t" tag "\t" hier "\t" d "\t" area "\t" pct "\t" comb "\t" noncomb "\t" black "\t" module

      if (d <= 1) {
        print key "\t" design "\t" tag "\t" hier "\t" area "\t" pct "\t" module >> out_top
      }
      pending=""
      next
    }

    # Line with hierarchy name only; next line may contain numbers.
    if (line ~ /^[^ \t]/ && $2 == "") {
      pending=$1
      next
    }

    # Continuation numeric line.
    if (pending != "" && line ~ /^[ \t]+[-+]?[0-9]/) {
      area=$1
      pct=$2
      comb=$3
      noncomb=$4
      black=$5
      module=""
      for (i=6;i<=NF;i++) module = module (module=="" ? "" : " ") $i

      hier=pending
      d=depth_of(hier)

      print key "\t" design "\t" tag "\t" hier "\t" d "\t" area "\t" pct "\t" comb "\t" noncomb "\t" black "\t" module

      if (d <= 1) {
        print key "\t" design "\t" tag "\t" hier "\t" area "\t" pct "\t" module >> out_top
      }
      pending=""
      next
    }
  }
  ' "$rpt" >> "$out_all"
}

parse_pnr_area() {
  local key="$1"
  local design="$2"
  local tag="$3"
  local rpt="$4"
  local out_all="$5"
  local out_top="$6"

  [[ -f "$rpt" ]] || return 0

  awk -v key="$key" -v design="$design" -v tag="$tag" -v out_top="$out_top" '
  function trim(s) {
    gsub(/^[ \t]+/, "", s)
    gsub(/[ \t]+$/, "", s)
    return s
  }
  function depth_of(s, t) {
    t=s
    return gsub("/", "/", t)
  }
  BEGIN { in_tbl=0 }
  /Hinst Name/ && /Module Name/ && /Total Area/ { in_tbl=1; next }
  in_tbl==1 && /^[-]+/ { next }
  in_tbl==1 {
    if ($0 ~ /^[ \t]*$/) next

    line=$0

    # PNR format is fixed-width-ish:
    # Hinst Name in col 1-47
    # Module Name in col 48-129
    # Inst Count and Total Area at end
    hinst=trim(substr(line,1,48))
    rest=trim(substr(line,49))

    n=split(rest,a,/[\t ]+/)
    if (n < 3) next

    total_area=a[n]
    inst_count=a[n-1]
    module=""
    for (i=1;i<=n-2;i++) module = module (module=="" ? "" : " ") a[i]

    if (hinst == "" || total_area !~ /^[-+]?[0-9]*\.?[0-9]+$/ || inst_count !~ /^[0-9]+$/) next

    d=depth_of(hinst)

    print key "\t" design "\t" tag "\t" hinst "\t" d "\t" module "\t" inst_count "\t" total_area

    if (d <= 1) {
      print key "\t" design "\t" tag "\t" hinst "\t" module "\t" inst_count "\t" total_area >> out_top
    }
  }
  ' "$rpt" >> "$out_all"
}

get_dc_total_area_from_tsv() {
  local key="$1"
  local tag="$2"
  awk -F'\t' -v key="$key" -v tag="$tag" 'NR>1 && $1==key && $3==tag && $5==0 { print $6; exit }' "$DC_ALL_TSV"
}

get_pnr_total_area_from_tsv() {
  local key="$1"
  local tag="$2"
  awk -F'\t' -v key="$key" -v tag="$tag" 'NR>1 && $1==key && $3==tag && $5==0 { print $8; exit }' "$PNR_ALL_TSV"
}

echo "[INFO] PROJ_ROOT   = ${PROJ_ROOT}"
echo "[INFO] RESULT_ROOT = ${RESULT_ROOT}"
echo "[INFO] MODULE_ROOT = ${MODULE_ROOT}"
echo "[INFO] Discovering cases from pnr/runs_*"

mapfile -t RUN_DIRS < <(find "${PROJ_ROOT}/pnr" -maxdepth 1 -type d -name "runs_*" | sort)

for run_dir in "${RUN_DIRS[@]}"; do
  base="$(basename "$run_dir")"
  tag="${base#runs_}"

  if ! is_known_tag "$tag"; then
    echo "[SKIP] $tag"
    continue
  fi

  key="$(guess_key "$tag")"
  design="$(guess_design_name "$tag")"

  if [[ "$design" == "UNKNOWN" ]]; then
    echo "[SKIP] $tag has UNKNOWN design"
    continue
  fi

  out="${RESULT_ROOT}/${key}"

  mkdir -p "$out"/{area,power,timing,reports}

  echo ""
  echo "======================================================================"
  echo "[INFO] Collecting key=${key}, design=${design}, tag=${tag}"
  echo "======================================================================"

  dc_rpt="$(find_dc_area_report "$tag")"
  pnr_rpt="$(find_pnr_area_report "$tag")"
  allrc="$(find_allrc_summary "$tag")"
  fmax="$(find_fmax_summary "$tag")"
  power_rpt="$(find_power_report "$tag")"

  echo "[INFO] DC area report : ${dc_rpt:-NA}"
  echo "[INFO] PNR area report: ${pnr_rpt:-NA}"
  echo "[INFO] Timing allrc   : ${allrc:-NA}"
  echo "[INFO] Timing fmax    : ${fmax:-NA}"
  echo "[INFO] Power report   : ${power_rpt:-NA}"

  if [[ -n "$dc_rpt" && -f "$dc_rpt" ]]; then
    cp -a "$dc_rpt" "$out/reports/dc_area_report.rpt" 2>/dev/null || true
    parse_dc_area "$key" "$design" "$tag" "$dc_rpt" "$DC_ALL_TSV" "$DC_TOP_TSV"
  fi

  if [[ -n "$pnr_rpt" && -f "$pnr_rpt" ]]; then
    cp -a "$pnr_rpt" "$out/reports/pnr_area_report.rpt" 2>/dev/null || true
    parse_pnr_area "$key" "$design" "$tag" "$pnr_rpt" "$PNR_ALL_TSV" "$PNR_TOP_TSV"
  fi

  power_w="$(extract_power_w "$power_rpt")"
  wns_pair="$(extract_wns_pair "$allrc")"
  setup_wns="${wns_pair%%|*}"
  hold_wns="${wns_pair#*|}"

  dc_total="$(get_dc_total_area_from_tsv "$key" "$tag")"
  pnr_total="$(get_pnr_total_area_from_tsv "$key" "$tag")"
  [[ -z "$dc_total" ]] && dc_total="NA"
  [[ -z "$pnr_total" ]] && pnr_total="NA"

  {
    echo "key=${key}"
    echo "design=${design}"
    echo "tag=${tag}"
    echo "dc_area_report=${dc_rpt:-NA}"
    echo "pnr_area_report=${pnr_rpt:-NA}"
    echo "allrc=${allrc:-NA}"
    echo "fmax=${fmax:-NA}"
    echo "power_rpt=${power_rpt:-NA}"
    echo "dc_total_area=${dc_total}"
    echo "pnr_total_area=${pnr_total}"
    echo "power_w=${power_w}"
    echo "worst_setup_wns=${setup_wns}"
    echo "worst_hold_wns=${hold_wns}"
  } > "$out/status.txt"

  {
    echo "======================================================================"
    echo "Top-level DC module area for ${key}"
    echo "======================================================================"
    awk -F'\t' -v key="$key" -v tag="$tag" 'NR==1 || ($1==key && $3==tag) {print}' "$DC_TOP_TSV"
    echo ""
    echo "======================================================================"
    echo "Top-level PNR module area for ${key}"
    echo "======================================================================"
    awk -F'\t' -v key="$key" -v tag="$tag" 'NR==1 || ($1==key && $3==tag) {print}' "$PNR_TOP_TSV"
  } > "$out/area/module_area_top.txt"

  {
    echo "======================================================================"
    echo "Power report for ${key}"
    echo "======================================================================"
    echo "power_rpt=${power_rpt:-NA}"
    echo ""
    if [[ -f "$power_rpt" ]]; then
      sed -n '1,220p' "$power_rpt"
    else
      echo "No ordinary PPA power_total.rpt found."
      echo "This script intentionally ignores pt/power_workloads/${tag}/..."
    fi
  } > "$out/power/power_extract.txt"

  {
    echo "======================================================================"
    echo "Timing summary for ${key}"
    echo "======================================================================"
    echo "allrc=${allrc:-NA}"
    echo "fmax=${fmax:-NA}"
    echo ""
    if [[ -f "$allrc" ]]; then
      echo "========== allrc =========="
      cat "$allrc"
      echo ""
    fi
    if [[ -f "$fmax" ]]; then
      echo "========== fmax =========="
      cat "$fmax"
      echo ""
    fi
  } > "$out/timing/timing_extract.txt"

  status_short="OK"
  case "$key" in
    abl_dec) status_short="OLD_DEC_CHECK_GLS" ;;
    abl_dec_holdfix) status_short="HOLD_FIX_DEC_CHECK_GLS" ;;
    *_holdfix) status_short="HOLD_FIX" ;;
  esac
  [[ "$power_w" == "NA" ]] && status_short="${status_short}_NO_POWER"
  [[ "$setup_wns" == "NA" || "$hold_wns" == "NA" ]] && status_short="${status_short}_NO_TIMING"

  echo -e "${key}\t${design}\t${tag}\t${dc_total}\t${pnr_total}\t${power_w}\t${setup_wns}\t${hold_wns}\t${status_short}" >> "$SUMMARY_TSV"
done

# Useful grouped summaries for report writing.
{
  echo "Module-level DC top area:"
  echo "  ${DC_TOP_TSV}"
  echo ""
  echo "Module-level PNR top area:"
  echo "  ${PNR_TOP_TSV}"
  echo ""
  echo "All DC hierarchy area:"
  echo "  ${DC_ALL_TSV}"
  echo ""
  echo "All PNR hierarchy area:"
  echo "  ${PNR_ALL_TSV}"
  echo ""
  echo "Notes:"
  echo "  - Ordinary PPA power is collected only from pt/runs_<tag>_power/..."
  echo "  - Workload power under pt/power_workloads/<tag>/... is intentionally ignored."
  echo "  - For holdfix tags, DC area reuses the corresponding base synthesis report."
} > "${MODULE_ROOT}/README.txt"

echo ""
echo "======================================================================"
echo "[DONE]"
echo "Summary:"
echo "  ${SUMMARY_TSV}"
echo ""
echo "Module area:"
echo "  ${DC_TOP_TSV}"
echo "  ${PNR_TOP_TSV}"
echo "  ${DC_ALL_TSV}"
echo "  ${PNR_ALL_TSV}"
echo "======================================================================"

if command -v column >/dev/null 2>&1; then
  echo ""
  echo "========== SUMMARY =========="
  column -t -s $'\t' "$SUMMARY_TSV"

  echo ""
  echo "========== DC TOP MODULE AREA =========="
  column -t -s $'\t' "$DC_TOP_TSV" | head -160

  echo ""
  echo "========== PNR TOP MODULE AREA =========="
  column -t -s $'\t' "$PNR_TOP_TSV" | head -160
else
  cat "$SUMMARY_TSV"
fi
