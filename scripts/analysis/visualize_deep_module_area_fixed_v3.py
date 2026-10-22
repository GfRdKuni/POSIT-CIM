#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
visualize_deep_module_area_fixed.py

Deep module area extraction + robust visualization.

Use:
  python3 visualize_deep_module_area_fixed.py \
    --module-pnr results/module_area_summary/module_area_pnr.tsv \
    --module-dc results/module_area_summary/module_area_dc.tsv \
    --outdir results/deep_module_area
"""

import argparse, re, textwrap
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

DESIGN_ORDER = ["top_hier", "abl_mf", "abl_mult", "abl_dec"]
DESIGN_LABEL = {"top_hier":"Top", "abl_mf":"Abl. MF", "abl_mult":"Abl. Mult", "abl_dec":"Abl. Dec"}
GROUP_ORDER = ["TC-BWC-MF","Conventional max finder","A2C-PD decoder","Conventional decoder",
               "MSA-DCM","Weight encoder / Booth","Activation LUT","Proposed arith path",
               "Conventional multiplier","Exponent adder","Adder tree","POSIT encoder",
               "Controller","Storage/RF","Other"]

def setup_matplotlib():
    plt.rcParams.update({
        "figure.dpi": 140, "savefig.dpi": 300, "font.size": 10,
        "axes.titlesize": 12, "axes.labelsize": 10,
        "xtick.labelsize": 9, "ytick.labelsize": 8, "legend.fontsize": 8,
        "axes.grid": True, "grid.alpha": 0.25, "grid.linestyle": "--",
        "figure.autolayout": False,
    })

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

def ensure_outdir(path):
    p = Path(path); p.mkdir(parents=True, exist_ok=True); return p

def savefig(outdir, name):
    png = outdir / (name + ".png")
    pdf = outdir / (name + ".pdf")
    plt.savefig(str(png), bbox_inches="tight", pad_inches=0.25)
    plt.savefig(str(pdf), bbox_inches="tight", pad_inches=0.25)
    print("[SAVE]", png); print("[SAVE]", pdf)

def normalize_module_table(df):
    df = df.copy()
    if "total_area" not in df.columns:
        if "area" in df.columns:
            df["total_area"] = df["area"]
        else:
            raise ValueError("Need total_area or area column.")
    if "hinst" not in df.columns and "hier_cell" in df.columns:
        df["hinst"] = df["hier_cell"]
    if "hinst" not in df.columns: df["hinst"] = ""
    if "module" not in df.columns: df["module"] = ""
    if "depth" not in df.columns:
        df["depth"] = df["hinst"].astype(str).apply(lambda s: s.count("/"))
    df = to_num(df, ["depth","inst_count","total_area","area","percent"])
    if "key" not in df.columns:
        raise ValueError("Need key column.")
    return df[df["key"].isin(DESIGN_ORDER)].copy()

def contains_token(text, patterns):
    t = str(text).lower()
    return any(re.search(p, t) for p in patterns)

def classify_row(row):
    module = str(row.get("module","")).lower()
    hinst = str(row.get("hinst","")).lower()
    text = module + " " + hinst

    if contains_token(text, [r"posit_cim_storage", r"posit_rf", r"\bsram\b", r"\bmem\b", r"\bram\b", r"\bstorage\b", r"\bbank\b", r"\bwrapper\b"]):
        return "Storage/RF"

    if contains_token(text, [r"\ba2c_pd\b", r"/u_a2c", r"/u_w_a2c", r"/u_a_a2c"]):
        return "A2C-PD decoder"
    if contains_token(text, [r"\bconv_posit_decoder\b", r"\bposit_decoder_conv\b"]):
        return "Conventional decoder"

    if contains_token(text, [r"\bmsa_dcm\b", r"/u_msa", r"\bmsa_lane\b"]):
        return "MSA-DCM"
    if contains_token(text, [r"\bweight_encode\b", r"/u_wenc", r"\bwenc\b", r"\bbooth\b"]):
        return "Weight encoder / Booth"
    if contains_token(text, [r"\bact_lut_setup\b", r"/u_alut", r"\balut\b", r"\bact_lut\b"]):
        return "Activation LUT"

    # Fix: match conv multiplier by hinst too, but avoid broad "abl_mult".
    if contains_token(text, [r"\bnormal_mult\b", r"\bconv_mult\b", r"\bconventional_mult\b", r"/u_mult\b", r"/u_conv_mult\b", r"/u_normal_mult\b"]):
        return "Conventional multiplier"

    if contains_token(text, [r"\btc_bwc_mf\b", r"\bbwc_mf\b", r"/u_mf\b", r"/u_tc_bwc_mf\b"]):
        return "TC-BWC-MF"
    if contains_token(text, [r"\bconv_max_finder\b", r"\bmax_finder\b", r"\bconventional_max\b", r"/u_conv_mf\b", r"/u_max_finder\b", r"/u_max\b"]):
        return "Conventional max finder"

    if contains_token(text, [r"\bexponent_adder\b", r"\beadd\b", r"/u_eadd\b"]):
        return "Exponent adder"
    if contains_token(text, [r"\badder_tree\b", r"/u_adder_tree\b"]):
        return "Adder tree"
    if contains_token(text, [r"\bposit_encoder\b", r"/u_enc\b"]):
        return "POSIT encoder"
    if contains_token(text, [r"\bcim_controller\b", r"\bcontroller\b", r"\bctrl\b"]):
        return "Controller"
    return "Other"

def add_groups(df):
    df = df.copy()
    df["module_group"] = df.apply(classify_row, axis=1)
    df["collapsed_group"] = df["module_group"].apply(
        lambda g: "Proposed arith path" if g in ["MSA-DCM","Weight encoder / Booth","Activation LUT"] else g
    )
    return df

def ordered_designs(keys):
    keys = list(keys)
    out = [k for k in DESIGN_ORDER if k in keys]
    out += [k for k in keys if k not in out]
    return out

def ordered_groups(groups):
    groups = list(groups)
    out = [g for g in GROUP_ORDER if g in groups]
    out += [g for g in groups if g not in out]
    return out

def make_tables(df, outdir):
    df.to_csv(outdir/"deep_module_area_classified.tsv", sep="\t", index=False)
    mg0 = safe_series(df, "module_group").astype(str)
    focus = df.loc[mg0 != "Other"].copy()
    focus.to_csv(outdir/"focus_module_instances.tsv", sep="\t", index=False)

    fine = focus.groupby(["key","module_group"])["total_area"].sum().reset_index().rename(columns={"total_area":"area"})
    fine["group_type"] = "fine"
    coll = focus.groupby(["key","collapsed_group"])["total_area"].sum().reset_index().rename(columns={"collapsed_group":"module_group","total_area":"area"})
    coll["group_type"] = "collapsed"
    group_area = pd.concat([fine, coll], ignore_index=True)
    group_area.to_csv(outdir/"focus_module_area_by_design.tsv", sep="\t", index=False)

    rows = []
    for key,g in df.groupby("key"):
        gg = g.sort_values("total_area", ascending=False).head(40).copy()
        gg["rank"] = np.arange(1, len(gg)+1)
        rows.append(gg)
    topn = pd.concat(rows, ignore_index=True) if rows else pd.DataFrame()
    topn.to_csv(outdir/"top_modules_by_design.tsv", sep="\t", index=False)
    print("[SAVE]", outdir/"deep_module_area_classified.tsv")
    print("[SAVE]", outdir/"focus_module_instances.tsv")
    print("[SAVE]", outdir/"focus_module_area_by_design.tsv")
    print("[SAVE]", outdir/"top_modules_by_design.tsv")
    return focus, group_area, topn

def safe_series(df, col):
    """
    Old pandas can behave badly if a dataframe accidentally contains duplicate
    column names. This helper always returns a 1-D Series.
    """
    obj = df.loc[:, col]
    if isinstance(obj, pd.DataFrame):
        obj = obj.iloc[:, 0]
    return obj


def area_of(group_area, key, group, group_type):
    # Be conservative for old pandas: convert comparison columns to string first.
    k = safe_series(group_area, "key").astype(str)
    g = safe_series(group_area, "module_group").astype(str)
    t = safe_series(group_area, "group_type").astype(str)

    mask = (k == str(key)) & (g == str(group)) & (t == str(group_type))
    x = group_area.loc[mask].copy()

    if x.empty:
        return np.nan

    area = pd.to_numeric(safe_series(x, "area"), errors="coerce").sum()
    return float(area) if np.isfinite(area) else np.nan

def make_pair_comparison(group_area, outdir):
    specs = [
        ("Max finder", "top_hier", "TC-BWC-MF", "abl_mf", "Conventional max finder", "fine"),
        ("Decoder", "top_hier", "A2C-PD decoder", "abl_dec", "Conventional decoder", "fine"),
        ("Arithmetic path", "top_hier", "Proposed arith path", "abl_mult", "Conventional multiplier", "collapsed"),
    ]
    rows, diag = [], []
    for name,pdsgn,pgrp,bdsgn,bgrp,gt in specs:
        pa = area_of(group_area,pdsgn,pgrp,gt)
        ba = area_of(group_area,bdsgn,bgrp,gt)
        if np.isfinite(pa) and np.isfinite(ba) and ba != 0:
            delta = (pa/ba - 1.0)*100.0
            reduction = (ba-pa)/ba*100.0
        else:
            delta = reduction = np.nan
        rows.append({
            "comparison_name": name, "proposed_design": pdsgn, "proposed_group": pgrp,
            "proposed_area": pa, "baseline_design": bdsgn, "baseline_group": bgrp,
            "baseline_area": ba, "proposed_delta_pct_vs_baseline": delta,
            "proposed_reduction_pct_vs_baseline": reduction, "group_type": gt,
        })
        if not np.isfinite(pa):
            diag.append({"comparison":name, "missing_side":"proposed", "design":pdsgn, "group":pgrp,
                         "suggestion":"Search deep_module_area_classified.tsv for actual module/hinst names; hierarchy may be flattened."})
        if not np.isfinite(ba):
            diag.append({"comparison":name, "missing_side":"baseline", "design":bdsgn, "group":bgrp,
                         "suggestion":"Search top_modules_by_design.tsv and focus_module_instances.tsv; add actual keyword to classify_row()."})
    out = pd.DataFrame(rows)
    out.to_csv(outdir/"innovation_pair_comparison.tsv", sep="\t", index=False)
    pd.DataFrame(diag).to_csv(outdir/"missing_module_diagnostics.tsv", sep="\t", index=False)
    print("[SAVE]", outdir/"innovation_pair_comparison.tsv")
    print("[SAVE]", outdir/"missing_module_diagnostics.tsv")
    return out

def wrap_label(s, width=24):
    return "\n".join(textwrap.wrap(str(s), width=width, break_long_words=False))

def plot_pair(pair_df, outdir):
    df = pair_df[np.isfinite(pair_df["proposed_area"]) & np.isfinite(pair_df["baseline_area"])].copy()
    if df.empty:
        print("[WARN] No complete pair comparison to plot.")
        return
    y = np.arange(len(df)); h = 0.35
    labels = [wrap_label(x,18) for x in df["comparison_name"]]
    plt.figure(figsize=(9.5, max(4.2, 1.0+len(df))))
    b1 = plt.barh(y-h/2, df["proposed_area"], height=h, label="Proposed block")
    b2 = plt.barh(y+h/2, df["baseline_area"], height=h, label="Baseline block")
    plt.yticks(y, labels)
    plt.xlabel("Module area (um$^2$)")
    plt.title("Innovation block area comparison")
    plt.legend(frameon=False)
    xmax = max(df["proposed_area"].max(), df["baseline_area"].max())
    for bars in (b1,b2):
        for b in bars:
            v = b.get_width()
            plt.text(v+0.01*xmax, b.get_y()+b.get_height()/2, "%.1f"%v, va="center", fontsize=8)
    savefig(outdir, "innovation_pair_area_comparison")
    plt.close()

def plot_stacked(group_area, outdir, group_type="collapsed", no_storage=True):
    df = group_area[group_area["group_type"]==group_type].copy()
    if no_storage:
        mg = safe_series(df, "module_group").astype(str)
        df = df.loc[mg != "Storage/RF"].copy()
    if df.empty: return
    table = df.pivot(index="key", columns="module_group", values="area").fillna(0.0)
    table = table.loc[ordered_designs(table.index), ordered_groups(table.columns)]
    x = np.arange(len(table.index)); bottom=np.zeros(len(table.index))
    plt.figure(figsize=(12,6.2))
    for g in table.columns:
        vals = table[g].values
        if np.all(vals==0): continue
        plt.bar(x, vals, bottom=bottom, label=g)
        bottom += vals
    plt.xticks(x, [DESIGN_LABEL.get(k,k) for k in table.index])
    plt.ylabel("Module area (um$^2$)")
    title = "Focused module area breakdown"
    if group_type=="collapsed": title += " (collapsed arithmetic path)"
    if no_storage: title += " without Storage/RF"
    plt.title(title)
    plt.legend(frameon=False, bbox_to_anchor=(1.02,1), loc="upper left")
    name = "focus_group_stacked_%s%s"%(group_type, "_no_storage" if no_storage else "")
    savefig(outdir,name); plt.close()
    table.to_csv(outdir/(name+".tsv"), sep="\t")
    print("[SAVE]", outdir/(name+".tsv"))

def plot_single(group_area, outdir, group_name, group_type="fine"):
    mg = safe_series(group_area, "module_group").astype(str)
    gt = safe_series(group_area, "group_type").astype(str)
    sub = group_area.loc[(mg == str(group_name)) & (gt == str(group_type))].copy()
    if sub.empty: return
    keys = ordered_designs(sub["key"].unique())
    vals = [float(sub[sub["key"]==k]["area"].sum()) if not sub[sub["key"]==k].empty else 0.0 for k in keys]
    y = np.arange(len(keys))
    plt.figure(figsize=(7.8, max(3.8, 0.65*len(keys)+1.5)))
    bars = plt.barh(y, vals)
    plt.yticks(y, [DESIGN_LABEL.get(k,k) for k in keys])
    plt.xlabel("Module area (um$^2$)")
    plt.title("%s area across designs"%group_name)
    xmax = max(vals) if vals else 1.0
    if xmax <= 0: xmax=1.0
    for b,v in zip(bars,vals):
        plt.text(v+0.01*xmax, b.get_y()+b.get_height()/2, "%.1f"%v, va="center", fontsize=8)
    safe = re.sub(r"[^A-Za-z0-9_]+","_",group_name).strip("_")
    savefig(outdir, "single_group_%s"%safe); plt.close()

def plot_topn(topn, outdir, n=15):
    if topn.empty: return
    for key in ordered_designs(topn["key"].unique()):
        kser = safe_series(topn, "key").astype(str)
        sub = topn.loc[kser == str(key)].sort_values("total_area", ascending=False).head(n)
        if sub.empty: continue
        labels = []
        for _,r in sub.iterrows():
            m,h = str(r.get("module","")), str(r.get("hinst",""))
            label = m if m and m!="nan" else h
            if h and h!="nan" and m and m!="nan":
                label = m+" | "+h
            labels.append(wrap_label(label,34))
        y=np.arange(len(sub)); vals=sub["total_area"].values
        plt.figure(figsize=(11,max(5.2,n*0.45)))
        plt.barh(y, vals); plt.yticks(y, labels); plt.gca().invert_yaxis()
        plt.xlabel("Area (um$^2$)")
        plt.title("Top %d hierarchy rows by area: %s"%(n, DESIGN_LABEL.get(key,key)))
        xmax=max(vals) if len(vals) else 1.0
        for yi,v in zip(y,vals):
            plt.text(v+0.01*xmax, yi, "%.1f"%v, va="center", fontsize=7)
        savefig(outdir, "top%d_modules_%s"%(n,key)); plt.close()

def write_readme(outdir):
    txt = """Deep module area outputs:
- deep_module_area_classified.tsv: full hierarchy rows with module_group/collapsed_group.
- focus_module_instances.tsv: all non-Other rows; inspect this before quoting.
- focus_module_area_by_design.tsv: area summed by design and module group.
- innovation_pair_comparison.tsv: direct innovation block comparisons.
- missing_module_diagnostics.tsv: missing groups if a comparison is incomplete.
- focus_group_stacked_*.png and single_group_*.png: visualization with larger layout.

If Conventional multiplier / A2C-PD is still missing, search top_modules_by_design.tsv
and add the actual module or hinst keyword to classify_row().
"""
    (outdir/"README.txt").write_text(txt)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--module-pnr", required=True)
    ap.add_argument("--module-dc", default=None)
    ap.add_argument("--summary", default=None)
    ap.add_argument("--outdir", default="results/deep_module_area")
    args = ap.parse_args()

    setup_matplotlib()
    outdir = ensure_outdir(args.outdir)
    pnr = add_groups(normalize_module_table(read_table(args.module_pnr)))
    focus, group_area, topn = make_tables(pnr, outdir)
    pair_df = make_pair_comparison(group_area, outdir)

    plot_pair(pair_df, outdir)
    plot_stacked(group_area, outdir, "fine", True)
    plot_stacked(group_area, outdir, "collapsed", True)

    for group,gt in [
        ("TC-BWC-MF","fine"), ("Conventional max finder","fine"),
        ("A2C-PD decoder","fine"), ("Conventional decoder","fine"),
        ("MSA-DCM","fine"), ("Weight encoder / Booth","fine"), ("Activation LUT","fine"),
        ("Proposed arith path","collapsed"), ("Conventional multiplier","collapsed"),
    ]:
        plot_single(group_area, outdir, group, gt)

    plot_topn(topn, outdir, 15)

    if args.module_dc:
        dc = add_groups(normalize_module_table(read_table(args.module_dc)))
        dc.to_csv(outdir/"deep_module_area_dc_classified.tsv", sep="\t", index=False)
        print("[SAVE]", outdir/"deep_module_area_dc_classified.tsv")

    write_readme(outdir)
    print("[SAVE]", outdir/"README.txt")
    print("[DONE] Deep module area analysis written to", outdir)

if __name__ == "__main__":
    main()
