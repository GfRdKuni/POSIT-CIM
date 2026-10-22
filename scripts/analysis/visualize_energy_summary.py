#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
visualize_energy_summary.py

Purpose:
  Visualize sparse workload energy results for posit_cim_28nm.

This version is compatible with older pandas versions:
  - no groupby(dropna=False)
  - no named aggregation syntax

Example:
  python3 visualize_energy_summary.py \
    --input results/energy_workloads/energy_summary.tsv \
    --outdir results/energy_workloads/figures \
    --only-pass
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt


DESIGN_ORDER = ["top_hier", "abl_mf", "abl_mult", "abl_dec"]
REGIME_ORDER = ["p16_l1", "p16_l2", "p8_l1"]

DESIGN_LABEL = {
    "top_hier": "Top (proposed)",
    "abl_mf": "Abl. max-finder",
    "abl_mult": "Abl. multiplier",
    "abl_dec": "Abl. decoder",
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
        "figure.autolayout": True,
    })


def ensure_outdir(path):
    outdir = Path(path)
    outdir.mkdir(parents=True, exist_ok=True)
    return outdir


def savefig(outdir, name):
    png = outdir / ("%s.png" % name)
    pdf = outdir / ("%s.pdf" % name)
    plt.savefig(str(png), bbox_inches="tight")
    plt.savefig(str(pdf), bbox_inches="tight")
    print("[SAVE] %s" % png)
    print("[SAVE] %s" % pdf)


def read_energy_file(path):
    df = pd.read_csv(path, sep="\t")
    if len(df.columns) <= 1:
        df = pd.read_csv(path, sep=r"\s+", engine="python")
    return df


def normalize_columns(df):
    required = [
        "tag", "run_name", "design_key", "regime",
        "a_sparsity_pct", "w_sparsity_pct",
        "power_w", "runtime_ns", "energy_j",
        "dense_ops", "effective_ops", "status",
    ]
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError("Missing required columns: %s" % missing)

    numeric_cols = [
        "clk_period_ns", "a_sparsity_pct", "w_sparsity_pct",
        "cycles", "busy_cycles", "dense_macs", "effective_macs",
        "dense_ops", "effective_ops", "power_w", "runtime_ns",
        "energy_j", "dense_tops", "effective_tops",
        "dense_tops_per_w", "effective_tops_per_w",
        "dense_pj_per_op", "effective_pj_per_op",
        "seed",
    ]
    for c in numeric_cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

    df["design_key"] = df["design_key"].astype(str)
    df["regime"] = df["regime"].astype(str)
    df["status"] = df["status"].astype(str)

    return df


def aggregate_by_run(df):
    """
    Aggregate op_idx rows into one row per design/regime/sparsity/run_name.

    Use sum(energy_j) / sum(ops), not simple average of row-level pJ/op.
    Compatible with old pandas versions.
    """
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
        row["pass_count"] = int((g["status"] == "PASS").sum())
        row["power_w_mean"] = g["power_w"].mean()
        row["runtime_ns_sum"] = g["runtime_ns"].sum()
        row["energy_j_sum"] = g["energy_j"].sum()
        row["dense_ops_sum"] = g["dense_ops"].sum()
        row["effective_ops_sum"] = g["effective_ops"].sum()

        if "cycles" in g.columns:
            row["cycles_sum"] = g["cycles"].sum()
        else:
            row["cycles_sum"] = len(g)

        rows.append(row)

    agg = pd.DataFrame(rows)

    if agg.empty:
        return agg

    agg["pass_rate"] = agg["pass_count"] / agg["op_count"]

    agg["dense_pj_per_op_agg"] = np.where(
        agg["dense_ops_sum"] > 0,
        agg["energy_j_sum"] / agg["dense_ops_sum"] * 1e12,
        np.nan,
    )
    agg["effective_pj_per_op_agg"] = np.where(
        agg["effective_ops_sum"] > 0,
        agg["energy_j_sum"] / agg["effective_ops_sum"] * 1e12,
        np.nan,
    )

    runtime_s = agg["runtime_ns_sum"] * 1e-9
    agg["dense_tops_agg"] = np.where(
        runtime_s > 0,
        agg["dense_ops_sum"] / runtime_s / 1e12,
        np.nan,
    )
    agg["effective_tops_agg"] = np.where(
        runtime_s > 0,
        agg["effective_ops_sum"] / runtime_s / 1e12,
        np.nan,
    )
    agg["dense_tops_per_w_agg"] = np.where(
        agg["power_w_mean"] > 0,
        agg["dense_tops_agg"] / agg["power_w_mean"],
        np.nan,
    )
    agg["effective_tops_per_w_agg"] = np.where(
        agg["power_w_mean"] > 0,
        agg["effective_tops_agg"] / agg["power_w_mean"],
        np.nan,
    )

    agg["total_sparsity_pct"] = (
        agg["a_sparsity_pct"].astype(float) + agg["w_sparsity_pct"].astype(float)
    ) / 2.0

    return agg


def aggregate_by_design_regime(run_df):
    """
    Aggregate all sparsity points for each design/regime.
    Compatible with old pandas versions.
    """
    rows = []

    for keys, g in run_df.groupby(["design_key", "regime"]):
        design_key, regime = keys

        row = {}
        row["design_key"] = design_key
        row["regime"] = regime
        row["runs"] = g["run_name"].nunique()
        row["pass_rate"] = g["pass_rate"].mean()
        row["mean_power_w"] = g["power_w_mean"].mean()
        row["total_energy_j"] = g["energy_j_sum"].sum()
        row["total_dense_ops"] = g["dense_ops_sum"].sum()
        row["total_effective_ops"] = g["effective_ops_sum"].sum()
        row["total_runtime_ns"] = g["runtime_ns_sum"].sum()
        row["mean_dense_pj_per_op"] = g["dense_pj_per_op_agg"].mean()
        row["mean_effective_pj_per_op"] = g["effective_pj_per_op_agg"].mean()
        row["mean_dense_tops_per_w"] = g["dense_tops_per_w_agg"].mean()
        row["mean_effective_tops_per_w"] = g["effective_tops_per_w_agg"].mean()

        rows.append(row)

    out = pd.DataFrame(rows)
    if out.empty:
        return out

    out["global_dense_pj_per_op"] = np.where(
        out["total_dense_ops"] > 0,
        out["total_energy_j"] / out["total_dense_ops"] * 1e12,
        np.nan,
    )
    out["global_effective_pj_per_op"] = np.where(
        out["total_effective_ops"] > 0,
        out["total_energy_j"] / out["total_effective_ops"] * 1e12,
        np.nan,
    )

    runtime_s = out["total_runtime_ns"] * 1e-9
    out["global_dense_tops"] = np.where(
        runtime_s > 0,
        out["total_dense_ops"] / runtime_s / 1e12,
        np.nan,
    )
    out["global_effective_tops"] = np.where(
        runtime_s > 0,
        out["total_effective_ops"] / runtime_s / 1e12,
        np.nan,
    )
    out["global_dense_tops_per_w"] = np.where(
        out["mean_power_w"] > 0,
        out["global_dense_tops"] / out["mean_power_w"],
        np.nan,
    )
    out["global_effective_tops_per_w"] = np.where(
        out["mean_power_w"] > 0,
        out["global_effective_tops"] / out["mean_power_w"],
        np.nan,
    )

    return out


def ordered_designs(df):
    present = list(df["design_key"].dropna().unique())
    return [d for d in DESIGN_ORDER if d in present] + [d for d in present if d not in DESIGN_ORDER]


def ordered_regimes(df):
    present = list(df["regime"].dropna().unique())
    return [r for r in REGIME_ORDER if r in present] + [r for r in present if r not in REGIME_ORDER]


def plot_grouped_bar(summary, outdir, metric, ylabel, title, name, lower_is_better=True):
    designs = ordered_designs(summary)
    regimes = ordered_regimes(summary)

    x = np.arange(len(regimes))
    width = 0.8 / max(len(designs), 1)

    plt.figure(figsize=(8.6, 4.8))

    for i, d in enumerate(designs):
        vals = []
        for r in regimes:
            row = summary[(summary["design_key"] == d) & (summary["regime"] == r)]
            vals.append(float(row[metric].iloc[0]) if len(row) else np.nan)

        offset = (i - (len(designs) - 1) / 2) * width
        label = DESIGN_LABEL.get(d, d)
        bars = plt.bar(x + offset, vals, width=width, label=label)

        for b, v in zip(bars, vals):
            if np.isfinite(v):
                txt = "%.2f" % v if abs(v) >= 1 else "%.3f" % v
                plt.text(
                    b.get_x() + b.get_width() / 2,
                    b.get_height(),
                    txt,
                    ha="center",
                    va="bottom",
                    fontsize=7,
                )

    plt.xticks(x, [REGIME_LABEL.get(r, r) for r in regimes])
    plt.ylabel(ylabel)
    plt.title(title)
    plt.legend(frameon=False, ncols=2)
    plt.figtext(0.99, 0.01, "Lower is better" if lower_is_better else "Higher is better",
                ha="right", fontsize=8)
    savefig(outdir, name)
    plt.close()


def plot_power_vs_sparsity(run_df, outdir):
    designs = ordered_designs(run_df)
    regimes = ordered_regimes(run_df)

    for r in regimes:
        plt.figure(figsize=(8.2, 4.8))
        sub_r = run_df[run_df["regime"] == r]

        for d in designs:
            sub = sub_r[sub_r["design_key"] == d]
            if sub.empty:
                continue

            curve = sub.groupby("total_sparsity_pct")["power_w_mean"].mean().reset_index()
            curve = curve.rename(columns={"power_w_mean": "power"})
            curve = curve.sort_values("total_sparsity_pct")

            plt.plot(
                curve["total_sparsity_pct"],
                curve["power"],
                marker="o",
                linewidth=2,
                label=DESIGN_LABEL.get(d, d),
            )

        plt.xlabel("Average sparsity = (A sparsity + W sparsity) / 2 (%)")
        plt.ylabel("Workload power (W)")
        plt.title("Workload power vs. sparsity (%s)" % REGIME_LABEL.get(r, r))
        plt.legend(frameon=False)
        savefig(outdir, "power_vs_sparsity_%s" % r)
        plt.close()


def plot_heatmap_for_design(run_df, outdir, design="top_hier",
                            metric="dense_pj_per_op_agg",
                            metric_label="Dense energy (pJ/op)"):
    regimes = ordered_regimes(run_df)
    ddf = run_df[run_df["design_key"] == design]
    if ddf.empty:
        return

    for r in regimes:
        sub = ddf[ddf["regime"] == r]
        if sub.empty:
            continue

        pivot = sub.groupby(["a_sparsity_pct", "w_sparsity_pct"])[metric].mean().reset_index()
        table = pivot.pivot(index="a_sparsity_pct", columns="w_sparsity_pct", values=metric)
        table = table.sort_index().sort_index(axis=1)

        plt.figure(figsize=(6.2, 5.2))
        im = plt.imshow(table.values, origin="lower", aspect="auto")
        cbar = plt.colorbar(im)
        cbar.set_label(metric_label)

        plt.xticks(np.arange(len(table.columns)), [str(int(c)) for c in table.columns])
        plt.yticks(np.arange(len(table.index)), [str(int(i)) for i in table.index])
        plt.xlabel("Weight sparsity (%)")
        plt.ylabel("Activation sparsity (%)")
        plt.title("%s %s\n%s" % (
            DESIGN_LABEL.get(design, design),
            metric_label,
            REGIME_LABEL.get(r, r),
        ))

        for i in range(table.shape[0]):
            for j in range(table.shape[1]):
                val = table.values[i, j]
                if np.isfinite(val):
                    plt.text(j, i, "%.1f" % val, ha="center", va="center", fontsize=7)

        savefig(outdir, "heatmap_%s_%s_%s" % (design, metric, r))
        plt.close()


def plot_top_vs_abl_mf_delta(summary, outdir):
    if "top_hier" not in set(summary["design_key"]) or "abl_mf" not in set(summary["design_key"]):
        return None

    regimes = ordered_regimes(summary)
    rows = []

    for r in regimes:
        top = summary[(summary["design_key"] == "top_hier") & (summary["regime"] == r)]
        mf = summary[(summary["design_key"] == "abl_mf") & (summary["regime"] == r)]
        if top.empty or mf.empty:
            continue

        top_power = float(top["mean_power_w"].iloc[0])
        mf_power = float(mf["mean_power_w"].iloc[0])
        top_pj = float(top["mean_dense_pj_per_op"].iloc[0])
        mf_pj = float(mf["mean_dense_pj_per_op"].iloc[0])

        rows.append({
            "regime": r,
            "power_delta_pct_top_vs_mf": (top_power / mf_power - 1.0) * 100.0,
            "dense_pj_delta_pct_top_vs_mf": (top_pj / mf_pj - 1.0) * 100.0,
        })

    delta = pd.DataFrame(rows)
    if delta.empty:
        return None

    x = np.arange(len(delta))
    width = 0.35

    plt.figure(figsize=(8.0, 4.6))
    b1 = plt.bar(
        x - width / 2,
        delta["power_delta_pct_top_vs_mf"],
        width=width,
        label="Power overhead",
    )
    b2 = plt.bar(
        x + width / 2,
        delta["dense_pj_delta_pct_top_vs_mf"],
        width=width,
        label="Dense pJ/op overhead",
    )

    plt.axhline(0, linewidth=1)
    plt.xticks(x, [REGIME_LABEL.get(r, r) for r in delta["regime"]])
    plt.ylabel("Top vs. Abl. max-finder delta (%)")
    plt.title("Top design overhead relative to max-finder ablation")
    plt.legend(frameon=False)

    for bars in (b1, b2):
        for b in bars:
            v = b.get_height()
            plt.text(
                b.get_x() + b.get_width() / 2,
                v,
                "%+.2f%%" % v,
                ha="center",
                va="bottom" if v >= 0 else "top",
                fontsize=8,
            )

    savefig(outdir, "top_vs_abl_mf_delta")
    plt.close()

    return delta


def plot_dense_vs_effective_energy(summary, outdir):
    designs = ordered_designs(summary)

    plt.figure(figsize=(7.4, 5.4))

    for d in designs:
        sub = summary[summary["design_key"] == d]
        if sub.empty:
            continue

        x = sub["mean_dense_pj_per_op"].values
        y = sub["mean_effective_pj_per_op"].values
        labels = sub["regime"].values

        plt.scatter(x, y, s=70, label=DESIGN_LABEL.get(d, d))
        for xi, yi, r in zip(x, y, labels):
            plt.text(xi, yi, REGIME_LABEL.get(r, r), fontsize=8, ha="left", va="bottom")

    plt.xlabel("Dense-normalized energy (pJ/op)")
    plt.ylabel("Effective-normalized energy (pJ/op)")
    plt.title("Dense vs. effective energy normalization")
    plt.legend(frameon=False)
    savefig(outdir, "dense_vs_effective_energy")
    plt.close()


def write_summary_tables(run_df, summary, outdir):
    run_path = outdir / "aggregated_by_run.tsv"
    summary_path = outdir / "summary_by_design_regime.tsv"

    run_df.to_csv(str(run_path), sep="\t", index=False)
    summary.to_csv(str(summary_path), sep="\t", index=False)

    print("[SAVE] %s" % run_path)
    print("[SAVE] %s" % summary_path)

    if "top_hier" in set(summary["design_key"]) and "abl_mf" in set(summary["design_key"]):
        rows = []
        for r in ordered_regimes(summary):
            top = summary[(summary["design_key"] == "top_hier") & (summary["regime"] == r)]
            mf = summary[(summary["design_key"] == "abl_mf") & (summary["regime"] == r)]
            mult = summary[(summary["design_key"] == "abl_mult") & (summary["regime"] == r)]
            if top.empty:
                continue

            item = {
                "regime": r,
                "top_power_w": float(top["mean_power_w"].iloc[0]),
                "top_dense_pj_op": float(top["mean_dense_pj_per_op"].iloc[0]),
                "top_dense_tops_per_w": float(top["mean_dense_tops_per_w"].iloc[0]),
            }

            if not mf.empty:
                item["top_vs_mf_power_delta_pct"] = (
                    item["top_power_w"] / float(mf["mean_power_w"].iloc[0]) - 1.0
                ) * 100.0
                item["top_vs_mf_dense_pj_delta_pct"] = (
                    item["top_dense_pj_op"] / float(mf["mean_dense_pj_per_op"].iloc[0]) - 1.0
                ) * 100.0

            if not mult.empty:
                item["top_vs_mult_power_delta_pct"] = (
                    item["top_power_w"] / float(mult["mean_power_w"].iloc[0]) - 1.0
                ) * 100.0
                item["top_vs_mult_dense_pj_delta_pct"] = (
                    item["top_dense_pj_op"] / float(mult["mean_dense_pj_per_op"].iloc[0]) - 1.0
                ) * 100.0

            rows.append(item)

        friendly = pd.DataFrame(rows)
        friendly_path = outdir / "top_hier_interpretation_table.tsv"
        friendly.to_csv(str(friendly_path), sep="\t", index=False)
        print("[SAVE] %s" % friendly_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Path to energy_summary.tsv/csv")
    parser.add_argument("--outdir", default="energy_figures", help="Output directory")
    parser.add_argument("--only-pass", action="store_true", help="Use only PASS rows")
    args = parser.parse_args()

    setup_matplotlib()
    outdir = ensure_outdir(args.outdir)

    df = read_energy_file(args.input)
    df = normalize_columns(df)

    if args.only_pass:
        df = df[df["status"] == "PASS"].copy()

    print("[INFO] Input rows:", len(df))
    print("[INFO] Designs:", sorted(df["design_key"].dropna().unique()))
    print("[INFO] Regimes:", sorted(df["regime"].dropna().unique()))
    print("[INFO] PASS rate:", (df["status"] == "PASS").mean())

    run_df = aggregate_by_run(df)
    summary = aggregate_by_design_regime(run_df)

    write_summary_tables(run_df, summary, outdir)

    plot_grouped_bar(
        summary,
        outdir,
        metric="mean_dense_pj_per_op",
        ylabel="Dense-normalized energy (pJ/op)",
        title="Dense-normalized energy by design and regime",
        name="bar_dense_pj_per_op",
        lower_is_better=True,
    )

    plot_grouped_bar(
        summary,
        outdir,
        metric="mean_dense_tops_per_w",
        ylabel="Dense TOPS/W",
        title="Dense-normalized energy efficiency by design and regime",
        name="bar_dense_tops_per_w",
        lower_is_better=False,
    )

    plot_grouped_bar(
        summary,
        outdir,
        metric="mean_power_w",
        ylabel="Mean workload power (W)",
        title="Mean workload power by design and regime",
        name="bar_mean_power_w",
        lower_is_better=True,
    )

    plot_power_vs_sparsity(run_df, outdir)

    plot_heatmap_for_design(
        run_df,
        outdir,
        design="top_hier",
        metric="dense_pj_per_op_agg",
        metric_label="Dense energy (pJ/op)",
    )

    plot_heatmap_for_design(
        run_df,
        outdir,
        design="top_hier",
        metric="power_w_mean",
        metric_label="Power (W)",
    )

    delta = plot_top_vs_abl_mf_delta(summary, outdir)
    if delta is not None:
        delta.to_csv(str(outdir / "top_vs_abl_mf_delta.tsv"), sep="\t", index=False)

    plot_dense_vs_effective_energy(summary, outdir)

    print("[DONE] Figures and tables written to:", outdir)


if __name__ == "__main__":
    main()
