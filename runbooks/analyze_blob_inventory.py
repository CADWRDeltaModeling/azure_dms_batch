#!/usr/bin/env python3
"""
Analyzes Azure Blob Inventory CSV reports to produce a per-container, per-tier
size summary.

Usage:
    python analyze_blob_inventory.py --accounts dwrbdoschismsa dwrbdodcpschismsa
    python analyze_blob_inventory.py --all          # all accounts in subscription
    python analyze_blob_inventory.py --local ./inventory_csvs/  # already-downloaded CSVs
    python analyze_blob_inventory.py --csv blob_inventory_2026-07-23.csv  # already-built
                                                                          # StorageAccount,Container,Tier,Size_MB,BlobCount
                                                                          # summary (e.g. from blob_inventory.sh); no Azure calls made

Requirements: azure-cli logged in (not needed for --csv), pandas, tqdm (optional)
"""

import argparse
import subprocess
import sys
import os
import glob
import tempfile
import pandas as pd


INVENTORY_CONTAINER = "blob-inventory-reports"


def run(cmd, check=True):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"ERROR: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def get_storage_accounts(names=None):
    """Return list of (account_name, resource_group) tuples."""
    raw = run("az storage account list --query '[].{name:name, rg:resourceGroup}' -o tsv")
    all_accounts = [line.split("\t") for line in raw.splitlines() if line]
    if names:
        all_accounts = [a for a in all_accounts if a[0] in names]
    return all_accounts


def download_inventory_csvs(account, rg, outdir):
    """Download all CSVs from blob-inventory-reports container into outdir."""
    key = run(f"az storage account keys list --account-name {account} --resource-group {rg} --query '[0].value' -o tsv")
    # List blobs in the inventory container
    blobs_raw = run(
        f"az storage blob list --account-name {account} --account-key '{key}' "
        f"--container-name {INVENTORY_CONTAINER} --query '[].name' -o tsv 2>/dev/null",
        check=False
    )
    if not blobs_raw:
        print(f"  [{account}] No inventory reports found yet.")
        return []

    downloaded = []
    for blob in blobs_raw.splitlines():
        if not blob.endswith(".csv"):
            continue
        local_path = os.path.join(outdir, f"{account}__{blob.replace('/', '__')}")
        print(f"  Downloading: {blob}")
        run(
            f"az storage blob download --account-name {account} --account-key '{key}' "
            f"--container-name {INVENTORY_CONTAINER} --name '{blob}' --file '{local_path}' --output none"
        )
        downloaded.append(local_path)
    return downloaded


def analyze_csvs(csv_files):
    """Load and aggregate inventory CSVs into a summary DataFrame."""
    dfs = []
    for f in csv_files:
        try:
            df = pd.read_csv(f, low_memory=False)
            # Normalize column names (Azure uses mixed case)
            df.columns = [c.strip() for c in df.columns]
            dfs.append(df)
        except Exception as e:
            print(f"  WARNING: Could not parse {f}: {e}")

    if not dfs:
        print("No valid inventory CSVs found.")
        sys.exit(1)

    combined = pd.concat(dfs, ignore_index=True)
    print(f"\nLoaded {len(combined):,} blobs from {len(csv_files)} CSV file(s).")

    # Extract container from blob Name (format: container/blob-path)
    combined["Container"] = combined["Name"].str.split("/").str[0]

    # Resolve effective tier: use AccessTier if set, else flag as Unknown
    def effective_tier(row):
        tier = row.get("AccessTier", "")
        inferred = str(row.get("AccessTierInferred", "")).lower()
        if pd.isna(tier) or str(tier).strip() == "" or str(tier).lower() == "nan":
            return "Unknown"
        return str(tier)

    combined["Tier"] = combined.apply(effective_tier, axis=1)

    # Size in MB
    combined["Size_MB"] = pd.to_numeric(combined.get("Content-Length", 0), errors="coerce").fillna(0) / 1024 / 1024

    # Aggregate per Container/Tier, then pivot tiers onto the same row per container
    long_form = (
        combined.groupby(["Container", "Tier"])
        .agg(Size_MB=("Size_MB", "sum"), BlobCount=("Name", "count"))
        .reset_index()
    )

    return pivot_by_tier(long_form, ["Container"])


def load_simple_inventory_csvs(csv_files):
    """Load already-built StorageAccount,Container,Tier,Size_MB,BlobCount CSV(s)
    (e.g. produced by blob_inventory.sh) without any Azure calls."""
    dfs = []
    for f in csv_files:
        try:
            df = pd.read_csv(f, low_memory=False)
            df.columns = [c.strip() for c in df.columns]
            dfs.append(df)
        except Exception as e:
            print(f"  WARNING: Could not parse {f}: {e}")

    if not dfs:
        print("No valid inventory CSVs found.")
        sys.exit(1)

    combined = pd.concat(dfs, ignore_index=True)
    required = {"StorageAccount", "Container", "Tier", "Size_MB", "BlobCount"}
    missing = required - set(combined.columns)
    if missing:
        print(f"ERROR: CSV is missing expected column(s): {', '.join(sorted(missing))}", file=sys.stderr)
        sys.exit(1)

    print(f"\nLoaded {len(combined):,} rows from {len(csv_files)} CSV file(s).")
    combined["Size_MB"] = pd.to_numeric(combined["Size_MB"], errors="coerce").fillna(0)
    combined["BlobCount"] = pd.to_numeric(combined["BlobCount"], errors="coerce").fillna(0).astype(int)
    return combined


TIER_ORDER = ["Hot", "Cool", "Cold", "Archive", "Unknown", "N/A"]


def pivot_by_tier(df, index_cols):
    """Pivot a long-form DataFrame (one row per index_cols+Tier) so that every
    entity in index_cols occupies a single row, with one Size_TB column per
    tier (Hot_TB, Cool_TB, Archive_TB, ...), plus Total_TB,
    Primary_Tier (the tier holding the most size) and BlobCount."""
    pivot = df.pivot_table(
        index=index_cols, columns="Tier", values="Size_MB",
        aggfunc="sum", fill_value=0,
    )

    # Order tier columns consistently, known tiers first
    tier_cols = [c for c in TIER_ORDER if c in pivot.columns] + \
                [c for c in pivot.columns if c not in TIER_ORDER]
    pivot = pivot[tier_cols]

    # Dominant tier = tier holding the most MB for that entity
    pivot["Primary_Tier"] = pivot[tier_cols].idxmax(axis=1)

    pivot["Total_MB"] = pivot[tier_cols].sum(axis=1)

    blob_counts = df.groupby(index_cols)["BlobCount"].sum()
    pivot = pivot.join(blob_counts.rename("BlobCount"))

    # Sort by total size (descending)
    pivot = pivot.reset_index().sort_values("Total_MB", ascending=False)

    # Convert MB -> TB (1 TB = 1024 * 1024 MB)
    MB_PER_TB = 1024 * 1024
    for c in tier_cols + ["Total_MB"]:
        pivot[c] = (pivot[c] / MB_PER_TB).round(4)

    # Rename tier/total columns to make the unit explicit (e.g. Hot -> Hot_TB)
    pivot = pivot.rename(columns={c: f"{c}_TB" for c in tier_cols})
    pivot = pivot.rename(columns={"Total_MB": "Total_TB"})

    ordered_cols = index_cols + [f"{c}_TB" for c in tier_cols] + \
                   ["Total_TB", "Primary_Tier", "BlobCount"]
    return pivot[ordered_cols]


def top_sized_containers(combined, top_n=20):
    """Aggregate a simple inventory DataFrame per (StorageAccount, Container),
    breaking size out by tier (Hot/Cool/Cold/Archive/...) as well as showing the
    total and the dominant (largest) tier. Returns the top_n largest containers
    by total size."""
    return pivot_by_tier(combined, ["StorageAccount", "Container"]).head(top_n)


def main():
    parser = argparse.ArgumentParser(description="Analyze Azure Blob Inventory reports")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--accounts", nargs="+", metavar="SA", help="Storage account name(s)")
    group.add_argument("--all", action="store_true", help="All storage accounts in subscription")
    group.add_argument("--local", metavar="DIR", help="Directory of already-downloaded CSV files")
    group.add_argument("--csv", nargs="+", metavar="FILE",
                        help="Already-built StorageAccount,Container,Tier,Size_MB,BlobCount "
                             "CSV file(s) (e.g. from blob_inventory.sh); analyzed directly, no Azure calls")
    parser.add_argument("--top", type=int, default=20, metavar="N",
                        help="Number of top sized containers to show when using --csv (default: 20)")
    parser.add_argument("--output", metavar="FILE", default="blob_inventory_summary.csv",
                        help="Output CSV file (default: blob_inventory_summary.csv)")
    args = parser.parse_args()

    if args.csv:
        for f in args.csv:
            if not os.path.isfile(f):
                print(f"ERROR: CSV file not found: {f}", file=sys.stderr)
                sys.exit(1)
        combined = load_simple_inventory_csvs(args.csv)
        top = top_sized_containers(combined, args.top)
        print(f"\n=== Top {len(top)} Largest Containers (size by tier) ===")
        print(top.to_string(index=False))
        top.to_csv(args.output, index=False)
        print(f"\nTop-containers summary saved to: {args.output}")
        return

    if args.local:
        csv_files = glob.glob(os.path.join(args.local, "**/*.csv"), recursive=True) + \
                    glob.glob(os.path.join(args.local, "*.csv"))
        if not csv_files:
            print(f"No CSV files found in {args.local}")
            sys.exit(1)
    else:
        accounts = get_storage_accounts(args.accounts if args.accounts else None)
        if not accounts:
            print("No matching storage accounts found.")
            sys.exit(1)
        print(f"Downloading inventory from {len(accounts)} account(s)...")
        with tempfile.TemporaryDirectory() as tmpdir:
            csv_files = []
            for name, rg in accounts:
                print(f"\n[{name}]")
                csv_files += download_inventory_csvs(name, rg, tmpdir)
            summary = analyze_csvs(csv_files)
            # Print and save before tmpdir is cleaned up
            print("\n=== Container Size by Tier (one row per container) ===")
            print(summary.to_string(index=False))
            summary.to_csv(args.output, index=False)
            print(f"\nSummary saved to: {args.output}")
        return

    summary = analyze_csvs(csv_files)
    print("\n=== Container Size by Tier (one row per container) ===")
    print(summary.to_string(index=False))
    summary.to_csv(args.output, index=False)
    print(f"\nSummary saved to: {args.output}")


if __name__ == "__main__":
    main()
