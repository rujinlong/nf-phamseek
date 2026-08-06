#!/usr/bin/env python3
"""Level-1 host depletion plus read-level diagnostics, in one streaming pass.

kraken2 has already classified every read, so the first pass of host removal is
free: reads landing in the Homo sapiens subtree are deleted here, and only what
remains is handed to the alignment-based level-2 pass.

Why this is not `extract_kraken_reads.py` (KrakenTools 1.2.1):

  * it holds one dict entry per retained read id, which for a 15 Gb ONT run is
    tens of millions of entries;
  * `--max` silently stops at 100,000,000 reads, truncating the output with no
    error;
  * it writes uncompressed FASTQ, adding tens of GB of intermediates per sample.

This script streams instead: kraken2 emits one output line per read in input
order, so the classification and the FASTQ are consumed in lockstep at flat
memory. Read ids are compared on every record, so if that ordering assumption is
ever violated the run aborts rather than silently emitting the wrong sequences.

The same pass also collects the chimera diagnostics. ONT cDNA libraries produce
concatemeric reads (ligation-derived tandems, and spacer-joined tandems from
pre-amplification).

These are NON-SPECIFIC AUXILIARY SIGNALS and must not be read as a chimera rate.
Measured on simulated cross-domain chimeras at a 30% chimera rate, the fraction
of reads assigned to root moved only from 0.16% to 0.70%: kraken2 resolves a
chimera towards whichever fragment contributes more k-mers rather than lifting
the assignment to root. The lift-distance distribution below carries more
information than the root fraction alone, but neither quantifies chimerism.
"""

from __future__ import annotations

import argparse
import gzip
import json
import sys
from pathlib import Path

N_CONF_BINS = 10

# Buckets for how far above the most specific available node an assignment sat:
# 0 = a leaf, 5 = five or more levels up.
N_LIFT_BINS = 6


def open_maybe_gzip(path: str, mode: str = "rt"):
    if str(path).endswith(".gz"):
        return gzip.open(path, mode)
    return open(path, mode)


def parse_report(report_path: Path):
    """Return (taxid -> rank_code, taxid -> depth, ordered rows).

    The kraken2 report encodes the tree as two-space indentation in the name
    column; that indentation is the only parent/child information available
    without the taxonomy dumps, so subtrees are derived from it.
    """
    rows = []
    ranks: dict[int, str] = {}
    with open(report_path) as fh:
        for line in fh:
            if not line.strip():
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 6:
                continue
            try:
                taxid = int(cols[-2])
            except ValueError:
                continue
            name_field = cols[-1]
            depth = (len(name_field) - len(name_field.lstrip(" "))) // 2
            rank = cols[-3].strip()
            rows.append((taxid, depth, rank))
            ranks[taxid] = rank
    return ranks, rows


def lift_distances(rows) -> dict:
    """taxid -> levels between it and the deepest node beneath it.

    0 means the read was placed on a leaf, i.e. as specifically as this database
    allows. Larger values mean kraken2's LCA stopped that many levels short of
    the most specific answer available, which happens both for reads shared
    between close relatives and for chimeras.
    """
    lift = {}
    for i, (taxid, depth, _rank) in enumerate(rows):
        deepest = depth
        for j in range(i + 1, len(rows)):
            if rows[j][1] <= depth:
                break
            deepest = max(deepest, rows[j][1])
        lift[taxid] = deepest - depth
    return lift


def internal_taxids(rows) -> set[int]:
    """Taxids that have at least one child in the report.

    Reads sitting on an internal node are where kraken2's LCA stopped early.
    Deriving this from the tree rather than from rank codes keeps it correct on
    the custom taxonomies used for phage databases, which frequently bottom out
    at order-level codes with no species node at all — a rank-code rule would
    then call almost every assignment "high order".
    """
    internal = set()
    for i, (taxid, depth, _rank) in enumerate(rows):
        if i + 1 < len(rows) and rows[i + 1][1] > depth:
            internal.add(taxid)
    return internal


def subtree_taxids(rows, root_taxid: int) -> set[int]:
    """Every taxid at or below `root_taxid`, from report indentation."""
    subtree: set[int] = set()
    active_depth: int | None = None
    for taxid, depth, _rank in rows:
        if active_depth is not None and depth <= active_depth:
            active_depth = None
        if taxid == root_taxid:
            active_depth = depth
            subtree.add(taxid)
        elif active_depth is not None and depth > active_depth:
            subtree.add(taxid)
    return subtree


def fastq_records(handle):
    while True:
        header = handle.readline()
        if not header:
            return
        seq = handle.readline()
        plus = handle.readline()
        qual = handle.readline()
        if not qual:
            raise SystemExit("ERROR: truncated FASTQ record")
        yield header, seq, plus, qual


def base_id(read_id: str) -> str:
    return read_id.split()[0] if read_id else ""


def kmer_profile(lca_field: str):
    """Parse kraken2's `taxid:count ...` column.

    Returns (total_kmers, distinct_non_root_taxa, dominant_fraction).
    `A` marks ambiguous (N-containing) k-mers and is excluded from the total.
    """
    total = 0
    counts: dict[str, int] = {}
    for token in lca_field.split():
        if ":" not in token:
            continue
        tid, _, cnt = token.partition(":")
        if tid == "A":
            continue
        try:
            n = int(cnt)
        except ValueError:
            continue
        total += n
        if tid not in ("0", "1"):
            counts[tid] = counts.get(tid, 0) + n
    if total == 0:
        return 0, 0, 0.0
    dominant = max(counts.values()) / total if counts else 0.0
    return total, len(counts), dominant


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kraken-output", required=True)
    ap.add_argument("--kraken-report", required=True, type=Path)
    ap.add_argument("--in-reads", required=True)
    ap.add_argument("--out-reads", required=True)
    ap.add_argument("--stats", required=True, type=Path)
    ap.add_argument("--diagnostics", required=True, type=Path)
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--host-taxid", type=int, default=9606)
    ap.add_argument("--viral-taxid", type=int, default=10239)
    ap.add_argument(
        "--drop-viral",
        action="store_true",
        help="Also withhold viral-classified reads from the level-2 aligner. "
        "Off by default: keeping them in closes the compliance gap where a "
        "human read misclassified as viral would bypass host depletion.",
    )
    args = ap.parse_args()

    ranks, rows = parse_report(args.kraken_report)
    internal_nodes = internal_taxids(rows)
    lift_by_taxid = lift_distances(rows)
    host_subtree = subtree_taxids(rows, args.host_taxid)
    viral_subtree = subtree_taxids(rows, args.viral_taxid)

    # A database without human decoy sequences has no 9606 node at all. That is
    # a supported configuration, but it must be visible in the report instead of
    # looking like a sample that simply contains no human sequence.
    host_in_db = bool(host_subtree)

    drop = set(host_subtree)
    if args.drop_viral:
        drop |= viral_subtree

    n_total = n_host = n_viral = n_unclassified = n_kept = 0
    n_root = n_internal = n_multitaxon = 0
    conf_hist = [0] * N_CONF_BINS
    lift_hist = [0] * N_LIFT_BINS
    conf_sum = 0.0
    n_scored = 0

    with open_maybe_gzip(args.kraken_output) as kfh, open_maybe_gzip(
        args.in_reads
    ) as rfh, gzip.open(args.out_reads, "wt", compresslevel=4) as ofh:

        rec_iter = fastq_records(rfh)

        for kline in kfh:
            if not kline.strip():
                continue
            cols = kline.rstrip("\n").split("\t")
            if len(cols) < 3:
                raise SystemExit(f"ERROR: malformed kraken2 output line: {kline[:120]}")
            status, kread_id, taxid_field = cols[0], cols[1], cols[2]
            lca_field = cols[4] if len(cols) > 4 else ""

            try:
                rec = next(rec_iter)
            except StopIteration:
                raise SystemExit(
                    "ERROR: kraken2 output has more records than the FASTQ input. "
                    "The classification and the reads are out of sync."
                )

            n_total += 1

            kid = base_id(kread_id)
            fid = base_id(rec[0][1:])
            if kid != fid:
                raise SystemExit(
                    f"ERROR: read order mismatch at record {n_total}: "
                    f"kraken2='{kid}' FASTQ='{fid}'. This build of kraken2 does "
                    "not preserve input order; the streaming split is unsafe and "
                    "the run has been stopped."
                )

            try:
                taxid = int(taxid_field)
            except ValueError:
                taxid = int(taxid_field.rsplit("taxid", 1)[-1].strip(" )"))

            # --- chimera diagnostics -------------------------------------
            total_kmers, distinct_taxa, dominant = kmer_profile(lca_field)
            if total_kmers:
                n_scored += 1
                conf_sum += dominant
                idx = min(int(dominant * N_CONF_BINS), N_CONF_BINS - 1)
                conf_hist[idx] += 1
                if distinct_taxa >= 2:
                    n_multitaxon += 1
            if taxid == 1:
                n_root += 1
            elif status != "U" and taxid in internal_nodes:
                n_internal += 1
            if status != "U" and taxid > 1:
                lift_hist[min(lift_by_taxid.get(taxid, 0), N_LIFT_BINS - 1)] += 1

            # --- classification tallies ----------------------------------
            if status == "U" or taxid == 0:
                n_unclassified += 1
            elif taxid in host_subtree:
                n_host += 1
            elif taxid in viral_subtree:
                n_viral += 1

            if taxid in drop and status != "U":
                continue

            n_kept += 1
            ofh.writelines(rec)

        if next(rec_iter, None) is not None:
            raise SystemExit(
                "ERROR: FASTQ input has more records than the kraken2 output. "
                "The classification and the reads are out of sync."
            )

    n_other = n_total - n_host - n_viral - n_unclassified
    pct_host = (100.0 * n_host / n_total) if n_total else 0.0

    def pct(x):
        return round(100.0 * x / n_total, 4) if n_total else 0.0

    with open(args.stats, "w") as fh:
        fh.write(
            "sample_id\treads_in\thost_reads_removed_l1\thost_removed_l1_pct\t"
            "viral_reads_l1\tother_reads_l1\tunclassified_reads_l1\treads_to_l2\t"
            "host_taxid_in_db\n"
        )
        fh.write(
            f"{args.sample_id}\t{n_total}\t{n_host}\t{pct_host:.4f}\t{n_viral}\t"
            f"{n_other}\t{n_unclassified}\t{n_kept}\t{str(host_in_db).upper()}\n"
        )

    diagnostics = {
        "sample_id": args.sample_id,
        "reads_total": n_total,
        "reads_classified": n_total - n_unclassified,
        "reads_unclassified": n_unclassified,
        "pct_unclassified": pct(n_unclassified),
        "reads_at_root": n_root,
        "pct_at_root": pct(n_root),
        "reads_at_internal_node": n_internal,
        "pct_at_internal_node": pct(n_internal),
        "reads_multitaxon_kmers": n_multitaxon,
        "pct_multitaxon_kmers": pct(n_multitaxon),
        "mean_dominant_kmer_fraction": round(conf_sum / n_scored, 4) if n_scored else 0.0,
        "dominant_kmer_fraction_hist": conf_hist,
        "lift_distance_hist": lift_hist,
        "lift_distance_bin_labels": [str(i) for i in range(N_LIFT_BINS - 1)]
        + [f"{N_LIFT_BINS - 1}+"],
        "hist_bin_edges": [round(i / N_CONF_BINS, 2) for i in range(N_CONF_BINS + 1)],
        "host_taxid_in_db": host_in_db,
    }
    with open(args.diagnostics, "w") as fh:
        json.dump(diagnostics, fh, indent=2)
        fh.write("\n")

    print(json.dumps({k: v for k, v in diagnostics.items() if k != "dominant_kmer_fraction_hist"}), file=sys.stderr)

    if not host_in_db:
        print(
            f"WARNING: taxid {args.host_taxid} is absent from this kraken2 database, "
            "so level-1 host depletion removed nothing and every read was passed to "
            "the level-2 aligner. Use a database built with human decoy sequences to "
            "get the fast first pass.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
