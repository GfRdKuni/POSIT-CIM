#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
plot_sparsity_evidence.py

Purpose:
  Generate thesis-friendly figures from sparsity trend tables.

Expected input directory:
  results/energy_workloads/trend_tables/

Required files:
  01_dense_to_sparse_summary.tsv
  02_total_sparsity_trend.tsv
  03_a_sparsity_sweep_by_w.tsv
  05_a_only_vs_w_only.tsv
  06_a_w_sensitivity.tsv

Recommended command:
  cd /path/to/projects/posit_cim_28nm

  python3 plot_sparsity_evidence.py \
    --indir results/energy_workloads/trend_tables \
    --outdir results/energy_workloads/sparsity_figures \
    --main-design top_hier \
    --baseline-design abl_mult

or:
  ilaunch python3 plot_sparsity_evidence.py \
    --indir results/energy_workloads/trend_tables \
    --outdir results/energy_workloads/sparsity_figures \
    --main-design top_hier \
    --baseline-design abl_mult

Generated figures:
  01_topsw_improvement_dense_to_sparse.png/pdf
  02_power_reduction_dense_to_sparse.png/pdf
  03_dense_pj_reduction_dense_to_sparse.png/pdf
  04_normalized_topsw_vs_total_sparsity.png/pdf
  05_normalized_power_vs_total_sparsity.png/pdf
  06_top_hier_power_heatmap_p16_l1.png/pdf
  07_top_hier_power_heatmap_p16_l2.png/pdf
  08_top_hier_power_heatmap_p8_l1.png/pdf
  09_a_only_vs_w_only_power_reduction_90.png/pdf
  10_power_sensitivity_slope_abs.png/pdf
  11_w_sparsity_slope_top_vs_baseline.png/pdf

Generated tables:
  plot_data_dense_to_sparse_focus.tsv
  plot_data_a_only_w_only_90.tsv
  plot_data_power_sensitivity.tsv

Notes:
  - Main metrics:
      power_w_mean: lower is better.
      dense_pj_per_op_agg: lower is better.
      dense_tops_per_w_agg: higher is better.
  - effective_pj_per_op_agg is intentionally not plotted by default because
    effective_ops can be extremely small at high sparsity.
"""

from __future__ import print_function

import argparse
import math
from pathlib import Path

import numpy as np
import pandas as pd

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch


REGIME_ORDER = ["p16_l1", "p16_l2", "p8_l1"]
DESIGN_ORDER = ["top_hier", "abl_mf", "abl_mult", "abl_dec"]

DESIGN_LABEL = {
    "top_hier": "Top",
    "abl_mf": "Abl. MF",
    "abl_mult": "Abl. Mult",
    "abl_dec": "Abl. Dec",
}

REGIME_LABEL = {
    "p16_l1": "P16-L1",
    "p16_l2": "P16-L2",
    "p8_l1": "P8-L1",
}


def setup_matplotlib():
    plt.rcParams.update({
        "figure.dpi": 140,
        "savefig.dpi": 300,
        "font.size": 10,
        "axes.titlesize": 12,
        "axes.labelsize": 10,
        "xtick.labelsize": 9,
        "ytick.labelsize": 9,
        "legend.fontsize": 9,
        "axes.grid": True,
        "grid.alpha": 0.25,
        "grid.linestyle": "--",
        "figure.autolayout": False,
    })


def ensure_outdir(path):
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


def read_tsv(path):
    df = pd.read_csv(str(path), sep="\t")
    if len(df.columns) <= 1:
        df = pd.read_csv(str(path), sep=r"\s+", engine="python")
    return df


def savefig(outdir, name):
    png = outdir / (name + ".png")
    pdf = outdir / (name + ".pdf")
    plt.savefig(str(png), bbox_inches="tight", pad_inches=0.25)
    plt.savefig(str(pdf), bbox_inches="tight", pad_inches=0.25)
    print("[SAVE]", png)
    print("[SAVE]", pdf)


def safe_legend(labels, colors=None, loc="best"):
    """
    Work around old matplotlib legend bug triggered by empty BarContainer /
    NaN-only bars on the server environment.

    colors:
      Optional list of matplotlib color specs. If provided, legend patches
      use the same colors as the plotted bars.
    """
    if colors is None:
        # Matplotlib default tab colors, matching the first two bar calls.
        colors = ["C0", "C1"]
    handles = []
    for i, lab in enumerate(labels):
        color = colors[i % len(colors)]
        handles.append(Patch(facecolor=color, edgecolor=color, label=str(lab)))
    plt.legend(handles=handles, frameon=False, loc=loc)



def to_num(df, cols):
    for c in cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def ordered_regimes(values):
    vals = list(values)
    out = [r for r in REGIME_ORDER if r in vals]
    out += [r for r in vals if r not in out]
    return out


def ordered_designs(values):
    vals = list(values)
    out = [d for d in DESIGN_ORDER if d in vals]
    out += [d for d in vals if d not in out]
    return out


def get_col(df, col):
    """Compatible with accidental duplicate columns in old pandas."""
    obj = df.loc[:, col]
    if isinstance(obj, pd.DataFrame):
        obj = obj.iloc[:, 0]
    return obj


def filter_designs(df, designs):
    d = get_col(df, "design_key").astype(str)
    return df.loc[d.isin([str(x) for x in designs])].copy()


def filter_regimes(df, regimes):
    r = get_col(df, "regime").astype(str)
    return df.loc[r.isin([str(x) for x in regimes])].copy()


def add_regime_order(df):
    df = df.copy()
    order = {r: i for i, r in enumerate(REGIME_ORDER)}
    df["_regime_order"] = get_col(df, "regime").astype(str).map(order).fillna(99)
    return df.sort_values(["_regime_order"]).drop(columns=["_regime_order"], errors="ignore")


def plot_dense_to_sparse_bars(summary, outdir, main_design, baseline_design):
    """
    Three grouped bar figures:
      1. TOPS/W improvement, higher is better.
      2. power reduction, higher is better.
      3. dense pJ/op reduction, higher is better.
    """
    df = filter_designs(summary, [main_design, baseline_design])
    df = add_regime_order(df)

    metrics = [
        (
            "dense_tops_per_w_agg_change_pct_sparse_vs_dense",
            "Dense-normalized TOPS/W improvement (%)",
            "01_topsw_improvement_dense_to_sparse",
            "Dense-normalized TOPS/W improvement from dense to 90% sparsity",
        ),
        (
            "power_w_mean_reduction_pct_dense_to_sparse",
            "Power reduction (%)",
            "02_power_reduction_dense_to_sparse",
            "Workload power reduction from dense to 90% sparsity",
        ),
        (
            "dense_pj_per_op_agg_reduction_pct_dense_to_sparse",
            "Dense pJ/op reduction (%)",
            "03_dense_pj_reduction_dense_to_sparse",
            "Dense-normalized energy reduction from dense to 90% sparsity",
        ),
    ]

    for col, ylabel, fname, title in metrics:
        if col not in df.columns:
            print("[WARN] Missing column:", col)
            continue

        regimes = ordered_regimes(df["regime"].unique())
        x = np.arange(len(regimes))
        width = 0.35

        vals_main = []
        vals_base = []
        for r in regimes:
            dser = get_col(df, "design_key").astype(str)
            rser = get_col(df, "regime").astype(str)
            m = df.loc[(dser == str(main_design)) & (rser == str(r))]
            b = df.loc[(dser == str(baseline_design)) & (rser == str(r))]
            vals_main.append(float(m[col].iloc[0]) if len(m) else np.nan)
            vals_base.append(float(b[col].iloc[0]) if len(b) else np.nan)

        plt.figure(figsize=(8.0, 4.8))
        b1 = plt.bar(x - width / 2, vals_main, width=width, label=DESIGN_LABEL.get(main_design, main_design))
        b2 = plt.bar(x + width / 2, vals_base, width=width, label=DESIGN_LABEL.get(baseline_design, baseline_design))

        plt.xticks(x, [REGIME_LABEL.get(r, r) for r in regimes])
        plt.ylabel(ylabel)
        plt.title(title)
        safe_legend([DESIGN_LABEL.get(main_design, main_design), DESIGN_LABEL.get(baseline_design, baseline_design)], colors=["C0", "C1"])
        plt.axhline(0, linewidth=1)

        ymax = np.nanmax(vals_main + vals_base) if len(vals_main + vals_base) else 1.0
        ymin = np.nanmin(vals_main + vals_base) if len(vals_main + vals_base) else 0.0
        span = max(1.0, ymax - ymin)

        for bars in [b1, b2]:
            for bar in bars:
                v = bar.get_height()
                if np.isfinite(v):
                    plt.text(
                        bar.get_x() + bar.get_width() / 2,
                        v + 0.02 * span if v >= 0 else v - 0.04 * span,
                        "%.2f" % v,
                        ha="center",
                        va="bottom" if v >= 0 else "top",
                        fontsize=8,
                    )

        savefig(outdir, fname)
        plt.close()

    # Save focus table.
    focus_cols = [
        "design_key", "regime",
        "dense_power_w_mean", "sparse_power_w_mean", "power_w_mean_reduction_pct_dense_to_sparse",
        "dense_dense_pj_per_op_agg", "sparse_dense_pj_per_op_agg", "dense_pj_per_op_agg_reduction_pct_dense_to_sparse",
        "dense_dense_tops_per_w_agg", "sparse_dense_tops_per_w_agg", "dense_tops_per_w_agg_change_pct_sparse_vs_dense",
    ]
    focus_cols = [c for c in focus_cols if c in df.columns]
    df[focus_cols].to_csv(str(outdir / "plot_data_dense_to_sparse_focus.tsv"), sep="\t", index=False)
    print("[SAVE]", outdir / "plot_data_dense_to_sparse_focus.tsv")


def normalize_by_dense(total_trend, metric):
    """
    For each design/regime, normalize metric by value at total_sparsity_pct=0.
    For TOPS/W, normalized value >1 is better.
    For power, normalized value <1 is better.
    """
    rows = []
    for (design, regime), g in total_trend.groupby(["design_key", "regime"]):
        g = g.sort_values("total_sparsity_pct").copy()
        dense = g.loc[pd.to_numeric(get_col(g, "total_sparsity_pct"), errors="coerce") == 0]
        if dense.empty:
            continue
        base = dense[metric].iloc[0]
        if not np.isfinite(base) or base == 0:
            continue
        gg = g[["design_key", "regime", "total_sparsity_pct", metric]].copy()
        gg["normalized"] = gg[metric] / base
        rows.append(gg)
    if rows:
        return pd.concat(rows, ignore_index=True)
    return pd.DataFrame(columns=["design_key", "regime", "total_sparsity_pct", metric, "normalized"])


def plot_normalized_trends(total_trend, outdir, main_design, baseline_design):
    """
    Plot normalized TOPS/W and normalized power vs total sparsity.
    Use one figure with regime panels for each metric.
    """
    configs = [
        (
            "dense_tops_per_w_agg",
            "Normalized dense TOPS/W",
            "04_normalized_topsw_vs_total_sparsity",
            "Dense TOPS/W normalized to dense case",
        ),
        (
            "power_w_mean",
            "Normalized power",
            "05_normalized_power_vs_total_sparsity",
            "Workload power normalized to dense case",
        ),
    ]

    for metric, ylabel, fname, title in configs:
        if metric not in total_trend.columns:
            print("[WARN] Missing metric:", metric)
            continue

        norm = normalize_by_dense(filter_designs(total_trend, [main_design, baseline_design]), metric)
        if norm.empty:
            continue

        regimes = ordered_regimes(norm["regime"].unique())
        n = len(regimes)
        plt.figure(figsize=(5.2 * n, 4.2))

        for i, r in enumerate(regimes, start=1):
            ax = plt.subplot(1, n, i)
            for design in [main_design, baseline_design]:
                dser = get_col(norm, "design_key").astype(str)
                rser = get_col(norm, "regime").astype(str)
                sub = norm.loc[(dser == str(design)) & (rser == str(r))].sort_values("total_sparsity_pct")
                if sub.empty:
                    continue
                ax.plot(
                    sub["total_sparsity_pct"].values,
                    sub["normalized"].values,
                    marker="o",
                    label=DESIGN_LABEL.get(design, design),
                )
            ax.set_title(REGIME_LABEL.get(r, r))
            ax.set_xlabel("Total sparsity (%)")
            ax.set_ylabel(ylabel if i == 1 else "")
            ax.axhline(1.0, linewidth=1)
            ax.legend(frameon=False)

        plt.suptitle(title, y=1.03)
        savefig(outdir, fname)
        plt.close()


def pivot_metric_for_heatmap(df, design, regime, metric):
    dser = get_col(df, "design_key").astype(str)
    rser = get_col(df, "regime").astype(str)
    sub = df.loc[(dser == str(design)) & (rser == str(regime))].copy()
    if sub.empty or metric not in sub.columns:
        return None
    pivot = sub.pivot(index="a_sparsity_pct", columns="w_sparsity_pct", values=metric)
    pivot = pivot.sort_index().sort_index(axis=1)
    return pivot


def plot_heatmap(matrix, outdir, fname, title, cbar_label):
    if matrix is None or matrix.empty:
        return
    data = matrix.values.astype(float)

    plt.figure(figsize=(6.6, 5.2))
    im = plt.imshow(data, origin="lower", aspect="auto")
    plt.colorbar(im, label=cbar_label)

    plt.xticks(np.arange(len(matrix.columns)), [str(int(x)) if float(x).is_integer() else str(x) for x in matrix.columns])
    plt.yticks(np.arange(len(matrix.index)), [str(int(x)) if float(x).is_integer() else str(x) for x in matrix.index])
    plt.xlabel("W sparsity (%)")
    plt.ylabel("A sparsity (%)")
    plt.title(title)

    # Annotate values.
    for i in range(data.shape[0]):
        for j in range(data.shape[1]):
            v = data[i, j]
            if np.isfinite(v):
                plt.text(j, i, "%.4f" % v, ha="center", va="center", fontsize=7)

    savefig(outdir, fname)
    plt.close()


def plot_main_design_heatmaps(a_sweep, outdir, main_design):
    """
    Heatmap for main design:
      power_w_mean per regime.
    """
    for idx, regime in enumerate(REGIME_ORDER, start=6):
        mat = pivot_metric_for_heatmap(a_sweep, main_design, regime, "power_w_mean")
        if mat is None:
            continue
        fname = "%02d_%s_power_heatmap_%s" % (idx, main_design, regime)
        title = "%s workload power: %s" % (DESIGN_LABEL.get(main_design, main_design), REGIME_LABEL.get(regime, regime))
        plot_heatmap(mat, outdir, fname, title, "Power (W)")


def plot_a_only_vs_w_only(a_vs_w, outdir, main_design, sparsity=90):
    """
    For main design, compare A-only and W-only power reduction at one sparsity level.
    """
    design_ser = get_col(a_vs_w, "design_key").astype(str)
    sparsity_ser = pd.to_numeric(get_col(a_vs_w, "sparsity_pct"), errors="coerce")
    df = a_vs_w.loc[
        (design_ser == str(main_design)) &
        (sparsity_ser == float(sparsity))
    ].copy()

    if df.empty:
        print("[WARN] No A-only/W-only data for design=%s sparsity=%s" % (main_design, sparsity))
        return

    df = add_regime_order(df)
    regimes = ordered_regimes(df["regime"].unique())
    x = np.arange(len(regimes))
    width = 0.35

    a_col = "a_only_power_w_mean_reduction_pct"
    w_col = "w_only_power_w_mean_reduction_pct"
    if a_col not in df.columns or w_col not in df.columns:
        print("[WARN] Missing A-only/W-only reduction columns")
        return

    avals = []
    wvals = []
    for r in regimes:
        sub = df.loc[get_col(df, "regime").astype(str) == str(r)]
        avals.append(float(sub[a_col].iloc[0]) if len(sub) else np.nan)
        wvals.append(float(sub[w_col].iloc[0]) if len(sub) else np.nan)

    plt.figure(figsize=(8.0, 4.8))
    b1 = plt.bar(x - width / 2, avals, width=width, label="A-only")
    b2 = plt.bar(x + width / 2, wvals, width=width, label="W-only")

    plt.xticks(x, [REGIME_LABEL.get(r, r) for r in regimes])
    plt.ylabel("Power reduction from dense (%)")
    plt.title("%s: A-only vs W-only sparsity at %d%%" % (DESIGN_LABEL.get(main_design, main_design), sparsity))
    safe_legend(["A-only", "W-only"], colors=["C0", "C1"])
    plt.axhline(0, linewidth=1)

    ymax = np.nanmax(avals + wvals) if len(avals + wvals) else 1.0
    ymin = np.nanmin(avals + wvals) if len(avals + wvals) else 0.0
    span = max(1.0, ymax - ymin)

    for bars in [b1, b2]:
        for bar in bars:
            v = bar.get_height()
            if np.isfinite(v):
                plt.text(
                    bar.get_x() + bar.get_width() / 2,
                    v + 0.02 * span,
                    "%.2f" % v,
                    ha="center",
                    va="bottom",
                    fontsize=8,
                )

    savefig(outdir, "09_a_only_vs_w_only_power_reduction_%d" % sparsity)
    plt.close()

    cols = ["design_key", "regime", "sparsity_pct", a_col, w_col, "a_minus_w_power_w_mean_reduction_pct_points"]
    cols = [c for c in cols if c in df.columns]
    aww_path = outdir / ("plot_data_a_only_w_only_%d.tsv" % sparsity)
    df[cols].to_csv(str(aww_path), sep="\t", index=False)
    print("[SAVE]", aww_path)


def plot_power_sensitivity(sens, outdir, main_design, baseline_design):
    """
    Plot absolute power slope magnitudes for A and W.
    Since slopes are negative, larger absolute value means stronger power reduction.
    """
    df = filter_designs(sens, [main_design, baseline_design]).copy()
    if df.empty:
        return

    a_col = "power_w_mean_slope_per_A_pct"
    w_col = "power_w_mean_slope_per_W_pct"
    if a_col not in df.columns or w_col not in df.columns:
        print("[WARN] Missing sensitivity slope columns")
        return

    df["abs_A_slope"] = df[a_col].abs()
    df["abs_W_slope"] = df[w_col].abs()

    # Figure 10: main design A/W slope.
    main = df.loc[get_col(df, "design_key").astype(str) == str(main_design)].copy()
    main = add_regime_order(main)
    regimes = ordered_regimes(main["regime"].unique())

    x = np.arange(len(regimes))
    width = 0.35
    avals = []
    wvals = []
    for r in regimes:
        sub = main.loc[get_col(main, "regime").astype(str) == str(r)]
        avals.append(float(sub["abs_A_slope"].iloc[0]) if len(sub) else np.nan)
        wvals.append(float(sub["abs_W_slope"].iloc[0]) if len(sub) else np.nan)

    plt.figure(figsize=(8.0, 4.8))
    b1 = plt.bar(x - width / 2, avals, width=width, label="A sparsity slope")
    b2 = plt.bar(x + width / 2, wvals, width=width, label="W sparsity slope")

    plt.xticks(x, [REGIME_LABEL.get(r, r) for r in regimes])
    plt.ylabel("|Power slope| (W / sparsity %)")
    plt.title("%s: power sensitivity to A/W sparsity" % DESIGN_LABEL.get(main_design, main_design))
    safe_legend(["A sparsity slope", "W sparsity slope"], colors=["C0", "C1"])

    ymax = np.nanmax(avals + wvals) if len(avals + wvals) else 1.0
    for bars in [b1, b2]:
        for bar in bars:
            v = bar.get_height()
            if np.isfinite(v):
                plt.text(
                    bar.get_x() + bar.get_width() / 2,
                    v + 0.02 * ymax,
                    "%.2e" % v,
                    ha="center",
                    va="bottom",
                    fontsize=8,
                )

    savefig(outdir, "10_power_sensitivity_slope_abs")
    plt.close()

    # Figure 11: W slope, top vs baseline.
    regimes = ordered_regimes(df["regime"].unique())
    x = np.arange(len(regimes))
    main_vals = []
    base_vals = []
    for r in regimes:
        dser = get_col(df, "design_key").astype(str)
        rser = get_col(df, "regime").astype(str)
        m = df.loc[(dser == str(main_design)) & (rser == str(r))]
        b = df.loc[(dser == str(baseline_design)) & (rser == str(r))]
        main_vals.append(float(m["abs_W_slope"].iloc[0]) if len(m) else np.nan)
        base_vals.append(float(b["abs_W_slope"].iloc[0]) if len(b) else np.nan)

    plt.figure(figsize=(8.0, 4.8))
    b1 = plt.bar(x - width / 2, main_vals, width=width, label=DESIGN_LABEL.get(main_design, main_design))
    b2 = plt.bar(x + width / 2, base_vals, width=width, label=DESIGN_LABEL.get(baseline_design, baseline_design))

    plt.xticks(x, [REGIME_LABEL.get(r, r) for r in regimes])
    plt.ylabel("|Power slope vs W sparsity| (W / sparsity %)")
    plt.title("Weight sparsity sensitivity: proposed vs conventional multiplier baseline")
    safe_legend([DESIGN_LABEL.get(main_design, main_design), DESIGN_LABEL.get(baseline_design, baseline_design)], colors=["C0", "C1"])

    ymax = np.nanmax(main_vals + base_vals) if len(main_vals + base_vals) else 1.0
    for bars in [b1, b2]:
        for bar in bars:
            v = bar.get_height()
            if np.isfinite(v):
                plt.text(
                    bar.get_x() + bar.get_width() / 2,
                    v + 0.02 * ymax,
                    "%.2e" % v,
                    ha="center",
                    va="bottom",
                    fontsize=8,
                )

    savefig(outdir, "11_w_sparsity_slope_top_vs_baseline")
    plt.close()

    cols = ["design_key", "regime", a_col, w_col, "abs_A_slope", "abs_W_slope", "power_w_mean_A_over_W_slope_ratio"]
    cols = [c for c in cols if c in df.columns]
    df[cols].to_csv(str(outdir / "plot_data_power_sensitivity.tsv"), sep="\t", index=False)
    print("[SAVE]", outdir / "plot_data_power_sensitivity.tsv")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--indir", required=True, help="Directory containing trend tables")
    ap.add_argument("--outdir", default="results/energy_workloads/sparsity_figures")
    ap.add_argument("--main-design", default="top_hier")
    ap.add_argument("--baseline-design", default="abl_mult")
    ap.add_argument("--a-w-sparsity", type=int, default=90, help="Sparsity level for A-only vs W-only comparison")
    args = ap.parse_args()

    setup_matplotlib()
    indir = Path(args.indir)
    outdir = ensure_outdir(args.outdir)

    # Read tables.
    summary = read_tsv(indir / "01_dense_to_sparse_summary.tsv")
    total = read_tsv(indir / "02_total_sparsity_trend.tsv")
    a_sweep = read_tsv(indir / "03_a_sparsity_sweep_by_w.tsv")
    a_vs_w = read_tsv(indir / "05_a_only_vs_w_only.tsv")
    sens = read_tsv(indir / "06_a_w_sensitivity.tsv")

    # Numeric conversion.
    # IMPORTANT:
    # Do NOT convert design_key/regime to numeric. Old versions converted all
    # columns and destroyed these string labels, causing empty filters and
    # zero/blank figures.
    numeric_cols_common = [
        "a_sparsity_pct", "w_sparsity_pct", "sparsity_pct", "total_sparsity_pct",
        "power_w_mean", "dense_pj_per_op_agg", "dense_tops_per_w_agg",
        "effective_pj_per_op_agg", "effective_tops_per_w_agg",
        "points",
    ]

    summary_numeric_cols = [
        c for c in summary.columns
        if c not in ["design_key", "regime"]
    ]
    total_numeric_cols = [
        c for c in total.columns
        if c not in ["design_key", "regime"]
    ]
    a_sweep_numeric_cols = [
        c for c in a_sweep.columns
        if c not in ["design_key", "regime"]
    ]
    a_vs_w_numeric_cols = [
        c for c in a_vs_w.columns
        if c not in ["design_key", "regime"]
    ]
    sens_numeric_cols = [
        c for c in sens.columns
        if c not in ["design_key", "regime"]
    ]

    summary = to_num(summary, summary_numeric_cols)
    total = to_num(total, total_numeric_cols)
    a_sweep = to_num(a_sweep, a_sweep_numeric_cols)
    a_vs_w = to_num(a_vs_w, a_vs_w_numeric_cols)
    sens = to_num(sens, sens_numeric_cols)

    # Make sure string key columns remain strings.
    for df_ in [summary, total, a_sweep, a_vs_w, sens]:
        if "design_key" in df_.columns:
            df_["design_key"] = df_["design_key"].astype(str)
        if "regime" in df_.columns:
            df_["regime"] = df_["regime"].astype(str)

    print("[CHECK] summary designs:", sorted(summary["design_key"].unique()) if "design_key" in summary.columns else "NO_DESIGN_KEY")
    print("[CHECK] summary regimes:", sorted(summary["regime"].unique()) if "regime" in summary.columns else "NO_REGIME")
    focus_check = summary[
        (summary["design_key"].astype(str).isin([str(args.main_design), str(args.baseline_design)]))
    ] if "design_key" in summary.columns else pd.DataFrame()
    print("[CHECK] dense_to_sparse focus rows:", len(focus_check))

    plot_dense_to_sparse_bars(summary, outdir, args.main_design, args.baseline_design)
    plot_normalized_trends(total, outdir, args.main_design, args.baseline_design)
    plot_main_design_heatmaps(a_sweep, outdir, args.main_design)
    plot_a_only_vs_w_only(a_vs_w, outdir, args.main_design, args.a_w_sparsity)
    plot_power_sensitivity(sens, outdir, args.main_design, args.baseline_design)

    readme = """Figure guide

01_topsw_improvement_dense_to_sparse:
  Dense TOPS/W improvement from A=0,W=0 to A=90,W=90.
  This is the most direct figure for showing stronger sparsity response.

02_power_reduction_dense_to_sparse:
  Workload power reduction from dense to high sparsity.

03_dense_pj_reduction_dense_to_sparse:
  Dense pJ/op reduction from dense to high sparsity.

04_normalized_topsw_vs_total_sparsity:
  TOPS/W trend normalized to each design/regime's dense case.
  It emphasizes relative improvement rather than absolute efficiency.

05_normalized_power_vs_total_sparsity:
  Power trend normalized to dense case.

06/07/08 heatmaps:
  top_hier power over A/W sparsity grid for each regime.

09_a_only_vs_w_only_power_reduction_90:
  Compare A-only and W-only sparsity effect at 90%.
  If W-only bars are higher, W sparsity has stronger power impact.

10_power_sensitivity_slope_abs:
  For top_hier, compare sensitivity to A and W sparsity.
  Larger absolute slope means stronger power reduction response.

11_w_sparsity_slope_top_vs_baseline:
  Compare W-sparsity sensitivity between top_hier and abl_mult.
"""
    (outdir / "README.txt").write_text(readme)
    print("[SAVE]", outdir / "README.txt")
    print("[DONE] sparsity evidence figures written to", outdir)


if __name__ == "__main__":
    main()
