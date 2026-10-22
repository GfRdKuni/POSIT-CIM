#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_favorable_evidence.py

Extract report-friendly evidence for three proposed innovations:
1) TC-BWC-MF maximum finder
2) MSA-DCM sparsity-aware Booth datapath
3) A2C-PD adder-less POSIT decoder

Compatible with old pandas (no named aggregation).
"""

import argparse
from pathlib import Path
import numpy as np
import pandas as pd

DESIGN_ORDER = ["top_hier", "abl_mf", "abl_mult", "abl_dec"]


def read_table(path):
    df = pd.read_csv(path, sep="\t")
    if len(df.columns) <= 1:
        df = pd.read_csv(path, sep=r"\s+", engine="python")
    return df


def to_numeric_if_exists(df, cols):
    for c in cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def pct_change(new, old):
    if old is None or pd.isna(old) or old == 0:
        return np.nan
    return (new / old - 1.0) * 100.0


def pct_reduction(new, old):
    if old is None or pd.isna(old) or old == 0:
        return np.nan
    return (old - new) / old * 100.0


def ensure_outdir(path):
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


def normalize_ppa(df):
    df = to_numeric_if_exists(df, [
        "dc_total_area", "pnr_total_area_fixed", "pnr_total_area",
        "power_w", "worst_setup_wns", "worst_hold_wns"
    ])
    if "pnr_total_area_fixed" not in df.columns and "pnr_total_area" in df.columns:
        df["pnr_total_area_fixed"] = df["pnr_total_area"]
    if "key" in df.columns:
        df = df[df["key"].isin(DESIGN_ORDER)].copy()
    return df


def ppa_relative_summary(ppa):
    rows = []
    if "key" not in ppa.columns:
        return pd.DataFrame(rows)

    base = ppa.set_index("key")
    if "top_hier" not in base.index:
        return pd.DataFrame(rows)

    for ref in ["abl_mf", "abl_mult", "abl_dec"]:
        if ref not in base.index:
            continue
        top = base.loc["top_hier"]
        other = base.loc[ref]
        rows.append({
            "comparison": "top_hier_vs_%s" % ref,
            "ref_design": ref,
            "top_pnr_area": top.get("pnr_total_area_fixed", np.nan),
            "ref_pnr_area": other.get("pnr_total_area_fixed", np.nan),
            "top_area_delta_pct_vs_ref": pct_change(top.get("pnr_total_area_fixed", np.nan), other.get("pnr_total_area_fixed", np.nan)),
            "top_power_w": top.get("power_w", np.nan),
            "ref_power_w": other.get("power_w", np.nan),
            "top_power_delta_pct_vs_ref": pct_change(top.get("power_w", np.nan), other.get("power_w", np.nan)),
            "top_setup_wns": top.get("worst_setup_wns", np.nan),
            "ref_setup_wns": other.get("worst_setup_wns", np.nan),
            "top_hold_wns": top.get("worst_hold_wns", np.nan),
            "ref_hold_wns": other.get("worst_hold_wns", np.nan),
        })
    return pd.DataFrame(rows)


def has_any(text, keywords):
    t = str(text).lower()
    return any(k.lower() in t for k in keywords)


def classify_module_from_text(text):
    t = str(text).lower()

    if has_any(t, ["storage", "posit_rf", "rf_", "sram", "mem", "ram", "bank", "wrapper"]):
        return "storage/RF"

    # Decoder path.
    if has_any(t, ["a2c_pd", "a2c", "posit_decoder", "conv_posit_decoder", "decoder"]):
        return "decoder_path"

    # Proposed arithmetic path.
    if has_any(t, ["msa_dcm", "u_msa", "msa"]):
        return "arith_path_msa"
    if has_any(t, ["weight_encode", "u_wenc", "wenc", "booth"]):
        return "arith_path_wenc"
    if has_any(t, ["act_lut", "u_alut", "alut", "lut_setup"]):
        return "arith_path_alut"

    # Conventional multiplier baseline.
    if has_any(t, ["normal_mult", "conv_mult"]):
        return "conv_mult_baseline"

    # Max finder.
    if has_any(t, ["tc_bwc_mf", "bwc_mf", "max_finder", "conv_max_finder", "u_mf", "u_max"]):
        return "max_finder"

    if has_any(t, ["exponent_adder", "eadd", "exponent"]):
        return "exponent_adder"
    if has_any(t, ["adder_tree", "adder"]):
        return "adder_tree"
    if has_any(t, ["posit_encoder", "encoder"]):
        return "posit_encoder"
    if has_any(t, ["controller", "ctrl"]):
        return "control"

    return "other"


def normalize_module(df):
    df = df.copy()
    if "total_area" not in df.columns:
        if "area" in df.columns:
            df["total_area"] = df["area"]
        else:
            raise ValueError("Module table needs total_area or area column.")
    df = to_numeric_if_exists(df, ["total_area", "area", "percent", "inst_count"])
    if "key" not in df.columns:
        raise ValueError("Module table needs key column.")
    if "module" not in df.columns:
        df["module"] = ""
    if "hinst" not in df.columns and "hier_cell" in df.columns:
        df["hinst"] = df["hier_cell"]
    if "hinst" not in df.columns:
        df["hinst"] = ""

    text = df["hinst"].astype(str) + " " + df["module"].astype(str)
    df["evidence_group"] = text.apply(classify_module_from_text)

    def collapse(g):
        if g in ["arith_path_msa", "arith_path_wenc", "arith_path_alut"]:
            return "proposed_arith_path_MSA_WENC_ALUT"
        return g

    df["evidence_group_collapsed"] = df["evidence_group"].apply(collapse)
    df = df[df["key"].isin(DESIGN_ORDER)].copy()
    return df


def module_group_area(module_df):
    rows = []
    fine = module_df.groupby(["key", "evidence_group"])["total_area"].sum().reset_index()
    fine = fine.rename(columns={"total_area": "area"})
    fine["group_type"] = "fine"
    rows.append(fine)

    collapsed = module_df.groupby(["key", "evidence_group_collapsed"])["total_area"].sum().reset_index()
    collapsed = collapsed.rename(columns={"evidence_group_collapsed": "evidence_group", "total_area": "area"})
    collapsed["group_type"] = "collapsed"
    rows.append(collapsed)

    return pd.concat(rows, ignore_index=True)


def area_of(module_area_df, key, group, group_type="collapsed"):
    x = module_area_df[
        (module_area_df["key"] == key) &
        (module_area_df["evidence_group"] == group) &
        (module_area_df["group_type"] == group_type)
    ]
    if x.empty:
        return np.nan
    return float(x["area"].sum())


def module_relative_summary(module_area_df):
    rows = []

    top_mf = area_of(module_area_df, "top_hier", "max_finder")
    abl_mf = area_of(module_area_df, "abl_mf", "max_finder")
    rows.append({
        "innovation": "TC-BWC-MF maximum finder",
        "comparison": "top_hier max_finder vs abl_mf max_finder",
        "top_area": top_mf,
        "baseline_area": abl_mf,
        "top_area_delta_pct_vs_baseline": pct_change(top_mf, abl_mf),
        "top_area_reduction_pct_vs_baseline": pct_reduction(top_mf, abl_mf),
        "note": "Positive reduction supports lower area for proposed max-finder."
    })

    top_arith = area_of(module_area_df, "top_hier", "proposed_arith_path_MSA_WENC_ALUT")
    abl_mult = area_of(module_area_df, "abl_mult", "conv_mult_baseline")
    rows.append({
        "innovation": "MSA-DCM / Booth sparsity-aware arithmetic path",
        "comparison": "top_hier (MSA+WENC+ALUT) vs abl_mult conv_mult",
        "top_area": top_arith,
        "baseline_area": abl_mult,
        "top_area_delta_pct_vs_baseline": pct_change(top_arith, abl_mult),
        "top_area_reduction_pct_vs_baseline": pct_reduction(top_arith, abl_mult),
        "note": "May be unfavorable in raw area; interpret as overhead for sparsity-aware multi-precision datapath."
    })

    top_dec = area_of(module_area_df, "top_hier", "decoder_path")
    abl_dec = area_of(module_area_df, "abl_dec", "decoder_path")
    rows.append({
        "innovation": "A2C-PD adder-less POSIT decoder",
        "comparison": "top_hier decoder_path vs abl_dec decoder_path",
        "top_area": top_dec,
        "baseline_area": abl_dec,
        "top_area_delta_pct_vs_baseline": pct_change(top_dec, abl_dec),
        "top_area_reduction_pct_vs_baseline": pct_reduction(top_dec, abl_dec),
        "note": "Positive reduction supports simpler decoder area."
    })

    return pd.DataFrame(rows)


def normalize_energy(df):
    df = df.copy()
    # aggregated_by_run.tsv path
    numeric_cols = [
        "a_sparsity_pct", "w_sparsity_pct", "power_w_mean",
        "energy_j_sum", "dense_ops_sum", "effective_ops_sum",
        "dense_pj_per_op_agg", "effective_pj_per_op_agg",
        "dense_tops_per_w_agg", "effective_tops_per_w_agg",
        "total_sparsity_pct", "pass_rate"
    ]
    df = to_numeric_if_exists(df, numeric_cols)

    # Raw energy_summary.tsv fallback.
    if "power_w_mean" not in df.columns:
        group_cols = ["tag", "design_key", "dut", "regime", "a_sparsity_pct", "w_sparsity_pct", "seed", "run_name"]
        group_cols = [c for c in group_cols if c in df.columns]
        rows = []
        for keys, g in df.groupby(group_cols):
            if not isinstance(keys, tuple):
                keys = (keys,)
            row = {}
            for c, v in zip(group_cols, keys):
                row[c] = v
            row["power_w_mean"] = pd.to_numeric(g["power_w"], errors="coerce").mean()
            row["energy_j_sum"] = pd.to_numeric(g["energy_j"], errors="coerce").sum()
            row["dense_ops_sum"] = pd.to_numeric(g["dense_ops"], errors="coerce").sum()
            row["effective_ops_sum"] = pd.to_numeric(g["effective_ops"], errors="coerce").sum()
            row["pass_rate"] = (g["status"].astype(str) == "PASS").mean() if "status" in g.columns else np.nan
            rows.append(row)
        df = pd.DataFrame(rows)
        df["dense_pj_per_op_agg"] = np.where(df["dense_ops_sum"] > 0, df["energy_j_sum"] / df["dense_ops_sum"] * 1e12, np.nan)
        df["effective_pj_per_op_agg"] = np.where(df["effective_ops_sum"] > 0, df["energy_j_sum"] / df["effective_ops_sum"] * 1e12, np.nan)

    if "total_sparsity_pct" not in df.columns:
        df["total_sparsity_pct"] = (df["a_sparsity_pct"].astype(float) + df["w_sparsity_pct"].astype(float)) / 2.0

    df = df[df["design_key"].isin(DESIGN_ORDER)].copy()
    return df


def sparsity_response_by_regime(energy):
    rows = []
    for keys, g in energy.groupby(["design_key", "regime"]):
        design, regime = keys
        dense = g[(g["a_sparsity_pct"] == 0) & (g["w_sparsity_pct"] == 0)]
        high_9090 = g[(g["a_sparsity_pct"] == 90) & (g["w_sparsity_pct"] == 90)]
        high_avg = g[g["total_sparsity_pct"] >= 75]

        dense_power = dense["power_w_mean"].mean() if not dense.empty else np.nan
        dense_pj = dense["dense_pj_per_op_agg"].mean() if not dense.empty else np.nan
        high_power = high_9090["power_w_mean"].mean() if not high_9090.empty else np.nan
        high_pj = high_9090["dense_pj_per_op_agg"].mean() if not high_9090.empty else np.nan
        high_avg_power = high_avg["power_w_mean"].mean() if not high_avg.empty else np.nan
        high_avg_pj = high_avg["dense_pj_per_op_agg"].mean() if not high_avg.empty else np.nan

        x = g["total_sparsity_pct"].astype(float).values
        y = g["power_w_mean"].astype(float).values
        valid = np.isfinite(x) & np.isfinite(y)
        if valid.sum() >= 2:
            slope, intercept = np.polyfit(x[valid], y[valid], 1)
        else:
            slope, intercept = np.nan, np.nan

        rows.append({
            "design_key": design,
            "regime": regime,
            "dense_power_w_A0W0": dense_power,
            "high_power_w_A90W90": high_power,
            "high_avg_power_w_sparsity_ge75": high_avg_power,
            "power_drop_pct_A90W90_vs_dense": pct_reduction(high_power, dense_power),
            "power_drop_pct_highavg_vs_dense": pct_reduction(high_avg_power, dense_power),
            "dense_pj_op_A0W0": dense_pj,
            "high_dense_pj_op_A90W90": high_pj,
            "high_avg_dense_pj_op_sparsity_ge75": high_avg_pj,
            "dense_pj_change_pct_A90W90_vs_dense": pct_change(high_pj, dense_pj),
            "dense_pj_change_pct_highavg_vs_dense": pct_change(high_avg_pj, dense_pj),
            "power_slope_w_per_sparsity_pct": slope,
            "relative_power_slope_pct_per_sparsity_pct": slope / dense_power * 100.0 if dense_power and np.isfinite(dense_power) else np.nan,
            "samples": len(g),
        })
    return pd.DataFrame(rows)


def sparsity_response_relative(resp):
    rows = []
    for regime in sorted(resp["regime"].unique()):
        top = resp[(resp["design_key"] == "top_hier") & (resp["regime"] == regime)]
        if top.empty:
            continue
        top = top.iloc[0]
        for ref in ["abl_mult", "abl_mf", "abl_dec"]:
            r = resp[(resp["design_key"] == ref) & (resp["regime"] == regime)]
            if r.empty:
                continue
            r = r.iloc[0]
            rows.append({
                "regime": regime,
                "comparison": "top_hier_vs_%s" % ref,
                "top_power_drop_pct_A90W90": top["power_drop_pct_A90W90_vs_dense"],
                "ref_power_drop_pct_A90W90": r["power_drop_pct_A90W90_vs_dense"],
                "top_minus_ref_drop_pct_points": top["power_drop_pct_A90W90_vs_dense"] - r["power_drop_pct_A90W90_vs_dense"],
                "top_relative_slope": top["relative_power_slope_pct_per_sparsity_pct"],
                "ref_relative_slope": r["relative_power_slope_pct_per_sparsity_pct"],
                "top_minus_ref_relative_slope": top["relative_power_slope_pct_per_sparsity_pct"] - r["relative_power_slope_pct_per_sparsity_pct"],
                "interpretation": "Positive drop-point advantage or more negative slope supports stronger sparsity responsiveness."
            })
    return pd.DataFrame(rows)


def fmt(v, nd=3):
    if v is None or pd.isna(v):
        return "NA"
    return ("%." + str(nd) + "f") % v


def generate_markdown(outdir, mod_rel, sparsity_rel):
    lines = []
    lines.append("# Favorable Evidence Summary")
    lines.append("")
    lines.append("This report extracts mechanism-oriented evidence without claiming results that are not supported by data.")
    lines.append("")

    lines.append("## 1. TC-BWC-MF maximum finder")
    rows = mod_rel[mod_rel["innovation"].str.contains("TC-BWC", na=False)]
    if not rows.empty:
        r = rows.iloc[0]
        lines.append("- Top max-finder area: `%s`" % fmt(r["top_area"], 3))
        lines.append("- Baseline max-finder area: `%s`" % fmt(r["baseline_area"], 3))
        lines.append("- Top area delta vs baseline: `%s%%`" % fmt(r["top_area_delta_pct_vs_baseline"], 2))
        lines.append("- Top area reduction vs baseline: `%s%%`" % fmt(r["top_area_reduction_pct_vs_baseline"], 2))
    else:
        lines.append("- No max-finder module comparison found. Check module classification.")

    lines.append("")
    lines.append("## 2. MSA-DCM sparsity responsiveness")
    rows = sparsity_rel[sparsity_rel["comparison"] == "top_hier_vs_abl_mult"]
    if not rows.empty:
        for _, r in rows.iterrows():
            lines.append("- `%s`: top_hier power-drop advantage vs conv_mult baseline = `%s` percentage points." %
                         (r["regime"], fmt(r["top_minus_ref_drop_pct_points"], 2)))
        lines.append("- If a value is positive, top_hier shows stronger power reduction as sparsity increases in that regime.")
        lines.append("- If values are negative, use this result honestly as a limitation and emphasize format-aware dynamic-cycle support rather than absolute superiority.")
    else:
        lines.append("- No top_hier vs abl_mult sparsity comparison found.")

    lines.append("")
    lines.append("## 3. A2C-PD decoder path")
    rows = mod_rel[mod_rel["innovation"].str.contains("A2C", na=False)]
    if not rows.empty:
        r = rows.iloc[0]
        lines.append("- Top decoder-path area: `%s`" % fmt(r["top_area"], 3))
        lines.append("- Decoder ablation area: `%s`" % fmt(r["baseline_area"], 3))
        lines.append("- Top area delta vs decoder ablation: `%s%%`" % fmt(r["top_area_delta_pct_vs_baseline"], 2))
        lines.append("- Top area reduction vs decoder ablation: `%s%%`" % fmt(r["top_area_reduction_pct_vs_baseline"], 2))
    else:
        lines.append("- No decoder module comparison found. Check module classification.")

    lines.append("")
    lines.append("## Suggested wording")
    lines.append("")
    lines.append("The conventional multiplier ablation may show lower raw dense energy. This should be interpreted as a low-complexity baseline that quantifies the hardware cost of the proposed POSIT-CIM datapath, not as a complete functional replacement. The proposed top_hier integrates adder-less POSIT decoding, sparsity-aware dynamic-cycle mantissa computation, comparator-free exponent maximum selection, multi-precision execution, and cross-batch accumulation.")
    path = outdir / "evidence_summary.md"
    path.write_text("\n".join(lines))
    return path


def generate_claims(outdir):
    text = """Recommended claim templates:

1. TC-BWC-MF:
   Emphasize direct replacement of comparator/subtractor tree with bit-wise survivor-mask logic. Use module_group_relative.tsv to report max-finder module area if favorable.

2. MSA-DCM:
   Do not claim universal raw-energy superiority over conv_mult unless sparsity_response tables support it. Emphasize POSIT-format-aware dynamic-cycle execution, local zero-group gating, and sparsity responsiveness.

3. A2C-PD:
   Emphasize adder-less negative-POSIT decoding and multi-cycle pitch-friendly regime extraction. Use decoder module area only if module_group_relative.tsv is favorable.

4. Timing:
   State clearly that current PPA is post-route pre-ECO and WNS is reported explicitly.
"""
    path = outdir / "recommended_claims.txt"
    path.write_text(text)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ppa", required=True)
    ap.add_argument("--module", required=True)
    ap.add_argument("--energy", required=True)
    ap.add_argument("--outdir", default="results/favorable_evidence")
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    ppa = normalize_ppa(read_table(args.ppa))
    module = normalize_module(read_table(args.module))
    energy = normalize_energy(read_table(args.energy))

    ppa_rel = ppa_relative_summary(ppa)
    mod_area = module_group_area(module)
    mod_rel = module_relative_summary(mod_area)
    sparsity_resp = sparsity_response_by_regime(energy)
    sparsity_rel = sparsity_response_relative(sparsity_resp)

    ppa_rel.to_csv(outdir / "ppa_relative_summary.tsv", sep="\t", index=False)
    mod_area.to_csv(outdir / "module_group_area.tsv", sep="\t", index=False)
    mod_rel.to_csv(outdir / "module_group_relative.tsv", sep="\t", index=False)
    sparsity_resp.to_csv(outdir / "sparsity_response_by_regime.tsv", sep="\t", index=False)
    sparsity_rel.to_csv(outdir / "sparsity_response_high_sparse.tsv", sep="\t", index=False)

    md = generate_markdown(outdir, mod_rel, sparsity_rel)
    claims = generate_claims(outdir)

    for f in [
        "ppa_relative_summary.tsv",
        "module_group_area.tsv",
        "module_group_relative.tsv",
        "sparsity_response_by_regime.tsv",
        "sparsity_response_high_sparse.tsv",
        "evidence_summary.md",
        "recommended_claims.txt",
    ]:
        print("[SAVE]", outdir / f)
    print("[DONE] Read", md)


if __name__ == "__main__":
    main()
