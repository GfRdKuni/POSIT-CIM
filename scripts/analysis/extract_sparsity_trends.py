#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_sparsity_trends.py

Purpose:
  Convert aggregated sparse workload energy results into thesis-friendly tables.

Input:
  results/energy_workloads/figures/aggregated_by_run.tsv
or:
  results/energy_workloads/energy_summary.tsv

Outputs:
  outdir/
    01_dense_to_sparse_summary.tsv
    02_total_sparsity_trend.tsv
    03_a_sparsity_sweep_by_w.tsv
    04_w_sparsity_sweep_by_a.tsv
    05_a_only_vs_w_only.tsv
    06_a_w_sensitivity.tsv
    pivot_power_by_total_sparsity.tsv
    pivot_dense_pj_by_total_sparsity.tsv
    pivot_dense_topsw_by_total_sparsity.tsv

Example:
  cd /path/to/projects/posit_cim_28nm

  python3 extract_sparsity_trends.py \
    --input results/energy_workloads/figures/aggregated_by_run.tsv \
    --outdir results/energy_workloads/trend_tables

Notes:
  - power_w_mean: workload power from SAIF/PrimePower.
  - dense_pj_per_op_agg: energy normalized by dense operation count.
  - effective_pj_per_op_agg can explode at high sparsity because effective_ops becomes tiny.
    It is still preserved, but not recommended as the main conclusion metric.
"""

import argparse
from pathlib import Path
import numpy as np
import pandas as pd


DESIGN_ORDER = ["top_hier", "abl_mf", "abl_mult", "abl_dec"]
REGIME_ORDER = ["p16_l1", "p16_l2", "p8_l1"]

METRICS = [
    "power_w_mean",
    "dense_pj_per_op_agg",
    "effective_pj_per_op_agg",
    "dense_tops_per_w_agg",
    "effective_tops_per_w_agg",
]


def read_table(path):
    df = pd.read_csv(path, sep="\t")
    if len(df.columns) <= 1:
        df = pd.read_csv(path, sep=r"\s+", engine="python")
    return df


def to_num(df, cols):
    for c in cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def normalize_input(df):
    """
    Accept either:
      1) aggregated_by_run.tsv, already one row per design/regime/A/W/seed
      2) raw energy_summary.tsv, one row per op_idx
    """
    df = df.copy()

    raw_cols = ["power_w", "runtime_ns", "energy_j", "dense_ops", "effective_ops", "status"]
    is_raw = ("power_w_mean" not in df.columns) and all(c in df.columns for c in ["power_w", "energy_j", "dense_ops", "effective_ops"])

    numeric_cols = [
        "a_sparsity_pct", "w_sparsity_pct", "seed", "cycles", "busy_cycles",
        "dense_ops", "effective_ops", "power_w", "runtime_ns", "energy_j",
        "power_w_mean", "runtime_ns_sum", "energy_j_sum",
        "dense_ops_sum", "effective_ops_sum",
        "dense_pj_per_op_agg", "effective_pj_per_op_agg",
        "dense_tops_per_w_agg", "effective_tops_per_w_agg",
        "pass_rate",
    ]
    df = to_num(df, numeric_cols)

    if is_raw:
        group_cols = [
            "tag", "design_key", "dut", "regime",
            "a_sparsity_pct", "w_sparsity_pct", "seed", "run_name",
        ]
        group_cols = [c for c in group_cols if c in df.columns]

        rows = []
        for keys, g in df.groupby(group_cols):
            if not isinstance(keys, tuple):
                keys = (keys,)
            row = {}
            for c, v in zip(group_cols, keys):
                row[c] = v

            row["op_count"] = len(g)
            row["pass_count"] = int((g["status"].astype(str) == "PASS").sum()) if "status" in g.columns else np.nan
            row["pass_rate"] = row["pass_count"] / float(row["op_count"]) if row["op_count"] else np.nan
            row["power_w_mean"] = g["power_w"].mean()
            row["runtime_ns_sum"] = g["runtime_ns"].sum() if "runtime_ns" in g.columns else np.nan
            row["energy_j_sum"] = g["energy_j"].sum()
            row["dense_ops_sum"] = g["dense_ops"].sum()
            row["effective_ops_sum"] = g["effective_ops"].sum()
            rows.append(row)

        df = pd.DataFrame(rows)

    # Make missing columns if needed.
    if "energy_j_sum" in df.columns and "dense_ops_sum" in df.columns:
        if "dense_pj_per_op_agg" not in df.columns:
            df["dense_pj_per_op_agg"] = np.where(
                df["dense_ops_sum"] > 0,
                df["energy_j_sum"] / df["dense_ops_sum"] * 1e12,
                np.nan,
            )
    if "energy_j_sum" in df.columns and "effective_ops_sum" in df.columns:
        if "effective_pj_per_op_agg" not in df.columns:
            df["effective_pj_per_op_agg"] = np.where(
                df["effective_ops_sum"] > 0,
                df["energy_j_sum"] / df["effective_ops_sum"] * 1e12,
                np.nan,
            )

    if "runtime_ns_sum" in df.columns and "dense_ops_sum" in df.columns:
        runtime_s = df["runtime_ns_sum"] * 1e-9
        if "dense_tops_per_w_agg" not in df.columns:
            dense_tops = np.where(runtime_s > 0, df["dense_ops_sum"] / runtime_s / 1e12, np.nan)
            df["dense_tops_per_w_agg"] = np.where(df["power_w_mean"] > 0, dense_tops / df["power_w_mean"], np.nan)
        if "effective_tops_per_w_agg" not in df.columns and "effective_ops_sum" in df.columns:
            effective_tops = np.where(runtime_s > 0, df["effective_ops_sum"] / runtime_s / 1e12, np.nan)
            df["effective_tops_per_w_agg"] = np.where(df["power_w_mean"] > 0, effective_tops / df["power_w_mean"], np.nan)

    df["total_sparsity_pct"] = (
        df["a_sparsity_pct"].astype(float) + df["w_sparsity_pct"].astype(float)
    ) / 2.0

    # Keep only PASS rows when pass_rate exists.
    if "pass_rate" in df.columns:
        df = df[df["pass_rate"].fillna(1.0) >= 0.999].copy()

    return df


def sort_design_regime(df):
    df = df.copy()
    design_rank = {d: i for i, d in enumerate(DESIGN_ORDER)}
    regime_rank = {r: i for i, r in enumerate(REGIME_ORDER)}
    df["_design_rank"] = df["design_key"].map(design_rank).fillna(99)
    df["_regime_rank"] = df["regime"].map(regime_rank).fillna(99)
    sort_cols = [c for c in ["_design_rank", "_regime_rank", "a_sparsity_pct", "w_sparsity_pct"] if c in df.columns]
    df = df.sort_values(sort_cols).drop(columns=["_design_rank", "_regime_rank"], errors="ignore")
    return df


def mean_group(df, group_cols):
    agg_cols = [c for c in METRICS if c in df.columns]
    rows = []
    for keys, g in df.groupby(group_cols):
        if not isinstance(keys, tuple):
            keys = (keys,)
        row = {}
        for c, v in zip(group_cols, keys):
            row[c] = v
        row["points"] = len(g)
        for m in agg_cols:
            row[m] = g[m].mean()
        rows.append(row)
    return pd.DataFrame(rows)


def dense_to_sparse_summary(df):
    """
    For each design/regime:
      dense point = A=0,W=0
      high sparse = A=90,W=90
      compute percentage changes.
    """
    rows = []
    for (design, regime), g in df.groupby(["design_key", "regime"]):
        dense = g[(g["a_sparsity_pct"] == 0) & (g["w_sparsity_pct"] == 0)]
        sparse = g[(g["a_sparsity_pct"] == 90) & (g["w_sparsity_pct"] == 90)]
        if dense.empty or sparse.empty:
            continue
        d = dense.iloc[0]
        s = sparse.iloc[0]

        row = {
            "design_key": design,
            "regime": regime,
            "dense_A": 0,
            "dense_W": 0,
            "sparse_A": 90,
            "sparse_W": 90,
        }
        for m in METRICS:
            if m in df.columns:
                dv = d[m]
                sv = s[m]
                row["dense_" + m] = dv
                row["sparse_" + m] = sv
                if pd.notna(dv) and dv != 0 and pd.notna(sv):
                    row[m + "_change_pct_sparse_vs_dense"] = (sv / dv - 1.0) * 100.0
                    row[m + "_reduction_pct_dense_to_sparse"] = (dv - sv) / dv * 100.0
                else:
                    row[m + "_change_pct_sparse_vs_dense"] = np.nan
                    row[m + "_reduction_pct_dense_to_sparse"] = np.nan
        rows.append(row)

    out = pd.DataFrame(rows)
    return sort_design_regime(out)


def total_sparsity_trend(df):
    """
    Average all A/W pairs with same total_sparsity_pct.
    This gives one clean trend per design/regime.
    """
    out = mean_group(df, ["design_key", "regime", "total_sparsity_pct"])
    return sort_design_regime(out)


def a_sparsity_sweep_by_w(df):
    """
    For each fixed W sparsity, sweep A sparsity.
    This answers: how activation sparsity affects metrics under fixed weight sparsity.
    """
    out = mean_group(df, ["design_key", "regime", "w_sparsity_pct", "a_sparsity_pct"])
    return sort_design_regime(out)


def w_sparsity_sweep_by_a(df):
    """
    For each fixed A sparsity, sweep W sparsity.
    This answers: how weight sparsity affects metrics under fixed activation sparsity.
    """
    out = mean_group(df, ["design_key", "regime", "a_sparsity_pct", "w_sparsity_pct"])
    return sort_design_regime(out)


def a_only_vs_w_only(df):
    """
    Compare A-only and W-only sparsity from dense baseline:
      A-only: A=s, W=0
      W-only: A=0, W=s
    """
    rows = []
    sparsities = sorted(set(df["a_sparsity_pct"].dropna().unique()).union(set(df["w_sparsity_pct"].dropna().unique())))
    sparsities = [s for s in sparsities if s != 0]

    for (design, regime), g in df.groupby(["design_key", "regime"]):
        dense = g[(g["a_sparsity_pct"] == 0) & (g["w_sparsity_pct"] == 0)]
        if dense.empty:
            continue
        dense = dense.iloc[0]

        for s in sparsities:
            aonly = g[(g["a_sparsity_pct"] == s) & (g["w_sparsity_pct"] == 0)]
            wonly = g[(g["a_sparsity_pct"] == 0) & (g["w_sparsity_pct"] == s)]

            row = {
                "design_key": design,
                "regime": regime,
                "sparsity_pct": s,
            }

            for m in METRICS:
                if m not in df.columns:
                    continue

                dv = dense[m]
                av = aonly.iloc[0][m] if not aonly.empty else np.nan
                wv = wonly.iloc[0][m] if not wonly.empty else np.nan

                row["dense_" + m] = dv
                row["a_only_" + m] = av
                row["w_only_" + m] = wv

                if pd.notna(dv) and dv != 0:
                    row["a_only_" + m + "_reduction_pct"] = (dv - av) / dv * 100.0 if pd.notna(av) else np.nan
                    row["w_only_" + m + "_reduction_pct"] = (dv - wv) / dv * 100.0 if pd.notna(wv) else np.nan
                    row["a_minus_w_" + m + "_reduction_pct_points"] = (
                        row["a_only_" + m + "_reduction_pct"] -
                        row["w_only_" + m + "_reduction_pct"]
                        if pd.notna(row["a_only_" + m + "_reduction_pct"]) and pd.notna(row["w_only_" + m + "_reduction_pct"])
                        else np.nan
                    )

            rows.append(row)

    out = pd.DataFrame(rows)
    return sort_design_regime(out)


def sensitivity_summary(df):
    """
    Fit simple slopes:
      metric = c0 + cA * A_sparsity + cW * W_sparsity
    for each design/regime.

    The coefficients roughly tell A/W sensitivity.
    For power and pJ/op:
      negative coefficient means metric decreases as sparsity increases.
    """
    rows = []
    for (design, regime), g in df.groupby(["design_key", "regime"]):
        A = g["a_sparsity_pct"].astype(float).values
        W = g["w_sparsity_pct"].astype(float).values
        X = np.vstack([np.ones_like(A), A, W]).T

        row = {
            "design_key": design,
            "regime": regime,
            "points": len(g),
        }

        for m in METRICS:
            if m not in g.columns:
                continue
            y = g[m].astype(float).values
            valid = np.isfinite(y) & np.isfinite(A) & np.isfinite(W)
            if valid.sum() >= 3:
                coef, _, _, _ = np.linalg.lstsq(X[valid], y[valid], rcond=None)
                c0, cA, cW = coef
                row[m + "_intercept"] = c0
                row[m + "_slope_per_A_pct"] = cA
                row[m + "_slope_per_W_pct"] = cW
                row[m + "_A_over_W_slope_ratio"] = cA / cW if cW != 0 else np.nan
            else:
                row[m + "_intercept"] = np.nan
                row[m + "_slope_per_A_pct"] = np.nan
                row[m + "_slope_per_W_pct"] = np.nan
                row[m + "_A_over_W_slope_ratio"] = np.nan

        rows.append(row)

    out = pd.DataFrame(rows)
    return sort_design_regime(out)


def make_pivots(total_trend, outdir):
    """
    Produce wide tables:
      row = total_sparsity_pct
      col = design/regime
      value = metric
    """
    for metric, filename in [
        ("power_w_mean", "pivot_power_by_total_sparsity.tsv"),
        ("dense_pj_per_op_agg", "pivot_dense_pj_by_total_sparsity.tsv"),
        ("dense_tops_per_w_agg", "pivot_dense_topsw_by_total_sparsity.tsv"),
    ]:
        if metric not in total_trend.columns:
            continue
        tmp = total_trend.copy()
        tmp["design_regime"] = tmp["design_key"].astype(str) + "__" + tmp["regime"].astype(str)
        pivot = tmp.pivot(index="total_sparsity_pct", columns="design_regime", values=metric)
        pivot = pivot.sort_index()
        pivot.to_csv(outdir / filename, sep="\t")


def write_readme(outdir):
    text = """Sparsity trend table guide

01_dense_to_sparse_summary.tsv
  For each design/regime, compares A=0,W=0 with A=90,W=90.
  Good for quick statement such as: power drops by X% from dense to high sparse.

02_total_sparsity_trend.tsv
  Averages all A/W combinations that have the same total sparsity = (A+W)/2.
  Good for clean line plots: metric vs total sparsity.

03_a_sparsity_sweep_by_w.tsv
  Keeps W sparsity fixed and sweeps A sparsity.
  Good for analyzing activation sparsity effect.

04_w_sparsity_sweep_by_a.tsv
  Keeps A sparsity fixed and sweeps W sparsity.
  Good for analyzing weight sparsity effect.

05_a_only_vs_w_only.tsv
  Compares A-only sparsity (A=s,W=0) and W-only sparsity (A=0,W=s)
  relative to dense baseline. Good for answering whether A or W sparsity
  has stronger power/energy impact.

06_a_w_sensitivity.tsv
  Fits metric = c0 + cA*A_sparsity + cW*W_sparsity.
  More negative slope means stronger reduction with sparsity.
  For power_w_mean, compare slope_per_A_pct and slope_per_W_pct.

Recommended thesis metrics:
  - power_w_mean
  - dense_pj_per_op_agg
  - dense_tops_per_w_agg

Use effective_pj_per_op_agg carefully:
  At very high sparsity, effective_ops_sum can be extremely small, so
  effective_pj_per_op_agg may explode due to fixed overhead.
"""
    (outdir / "README.txt").write_text(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="aggregated_by_run.tsv or raw energy_summary.tsv")
    ap.add_argument("--outdir", default="results/energy_workloads/trend_tables")
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    df = normalize_input(read_table(args.input))
    df = sort_design_regime(df)

    dense_sparse = dense_to_sparse_summary(df)
    total_trend = total_sparsity_trend(df)
    a_sweep = a_sparsity_sweep_by_w(df)
    w_sweep = w_sparsity_sweep_by_a(df)
    a_vs_w = a_only_vs_w_only(df)
    sens = sensitivity_summary(df)

    dense_sparse.to_csv(outdir / "01_dense_to_sparse_summary.tsv", sep="\t", index=False)
    total_trend.to_csv(outdir / "02_total_sparsity_trend.tsv", sep="\t", index=False)
    a_sweep.to_csv(outdir / "03_a_sparsity_sweep_by_w.tsv", sep="\t", index=False)
    w_sweep.to_csv(outdir / "04_w_sparsity_sweep_by_a.tsv", sep="\t", index=False)
    a_vs_w.to_csv(outdir / "05_a_only_vs_w_only.tsv", sep="\t", index=False)
    sens.to_csv(outdir / "06_a_w_sensitivity.tsv", sep="\t", index=False)

    make_pivots(total_trend, outdir)
    write_readme(outdir)

    print("[INFO] input rows:", len(df))
    print("[INFO] designs:", sorted(df["design_key"].unique()))
    print("[INFO] regimes:", sorted(df["regime"].unique()))
    print("[SAVE]", outdir / "01_dense_to_sparse_summary.tsv")
    print("[SAVE]", outdir / "02_total_sparsity_trend.tsv")
    print("[SAVE]", outdir / "03_a_sparsity_sweep_by_w.tsv")
    print("[SAVE]", outdir / "04_w_sparsity_sweep_by_a.tsv")
    print("[SAVE]", outdir / "05_a_only_vs_w_only.tsv")
    print("[SAVE]", outdir / "06_a_w_sensitivity.tsv")
    print("[DONE] trend tables written to", outdir)


if __name__ == "__main__":
    main()
