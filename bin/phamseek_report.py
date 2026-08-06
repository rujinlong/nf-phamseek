#!/usr/bin/env python3
"""Per-sample phamseek report: viral calls, QC, host depletion, chimera signals.

Evidence model for v0.1
-----------------------
v0.1 produces READ-LEVEL evidence only. There is no assembly, no geNomad and no
CheckV, so nothing here can be confirmed by an orthogonal line of evidence.
Every positive row is therefore a CANDIDATE, graded only by how far above the
reporting floor it sits. The wording is deliberate: an unconfirmed k-mer
assignment in a low-biomass sample is not a diagnosis.

Calls
  candidate_passes_abundance_screen  reads >= --min-reads and RPM >= --min-rpm
  candidate_low_abundance            reads >= --min-reads but RPM < --min-rpm
  below_threshold           reads <  --min-reads (kept in the table, never
                            silently dropped, so a reader can see what was seen)

Denominator
  RPM is computed over NON-HOST reads, not total reads. In plasma and CSF the
  human fraction dominates, and normalising by total reads would make the same
  organism look 100x rarer in a sample that simply had more host background.

Boundary conditions carried into every report (from the p0126 benchmark that
this pipeline is derived from):
  * recall depends on whether the reference database contains a >=80% ANI
    neighbour: ~96% when it does, ~50% when it does not. A negative result
    cannot exclude a novel phage.
  * plasmids and ICE/IME are the dominant residual false-positive source for
    k-mer classification and are NOT removable by raising --confidence
    (37.4% of plasmids called phage at c=0.02 without decoy sequences, <=0.4%
    with them).
  * read-level figures sit 5-34 points below contig-level figures.
  * precision is a function of sample composition, not a property of the
    classifier.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

VIRAL_TAXID = 10239


def parse_kraken_report(path: Path):
    """Return (rows, total_reads, unclassified_reads).

    rows: list of dicts with taxid, rank, name, depth, clade, direct.
    """
    rows = []
    unclassified = 0
    root_clade = 0
    with open(path) as fh:
        for line in fh:
            if not line.strip():
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 6:
                continue
            try:
                clade = int(cols[1])
                direct = int(cols[2])
                taxid = int(cols[-2])
            except ValueError:
                continue
            rank = cols[-3].strip()
            name_field = cols[-1]
            depth = (len(name_field) - len(name_field.lstrip(" "))) // 2
            name = name_field.strip()
            rows.append(
                {
                    "taxid": taxid,
                    "rank": rank,
                    "name": name,
                    "depth": depth,
                    "clade": clade,
                    "direct": direct,
                }
            )
            if taxid == 0:
                unclassified = clade
            elif taxid == 1:
                root_clade = clade
    return rows, root_clade + unclassified, unclassified


def subtree_rows(rows, root_taxid: int):
    """Rows at or below `root_taxid`, using report indentation as the tree."""
    out = []
    active_depth = None
    for r in rows:
        if active_depth is not None and r["depth"] <= active_depth:
            active_depth = None
        if r["taxid"] == root_taxid:
            active_depth = r["depth"]
            out.append(r)
        elif active_depth is not None and r["depth"] > active_depth:
            out.append(r)
    return out


def clade_reads_for(rows, taxid: int) -> int:
    for r in rows:
        if r["taxid"] == taxid:
            return r["clade"]
    return 0


def read_tsv(path: Path):
    """Read a one-data-row TSV into a dict; return {} when absent/placeholder."""
    if path is None or not Path(path).exists():
        return {}
    with open(path) as fh:
        lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    if len(lines) < 2:
        return {}
    header = lines[0].split("\t")
    values = lines[1].split("\t")
    return dict(zip(header, values))


def read_json(path: Path):
    if path is None or not Path(path).exists():
        return {}
    try:
        with open(path) as fh:
            return json.load(fh)
    except (json.JSONDecodeError, OSError):
        return {}


def load_bracken(path: Path):
    """taxid -> (est_reads, fraction). Empty when bracken did not run."""
    out = {}
    if path is None or not Path(path).exists():
        return out
    with open(path) as fh:
        header = fh.readline().rstrip("\n").split("\t")
        if "taxonomy_id" not in header:
            return out
        i_tid = header.index("taxonomy_id")
        i_est = header.index("new_est_reads") if "new_est_reads" in header else None
        i_frac = (
            header.index("fraction_total_reads")
            if "fraction_total_reads" in header
            else None
        )
        for line in fh:
            cols = line.rstrip("\n").split("\t")
            if len(cols) <= i_tid:
                continue
            try:
                tid = int(cols[i_tid])
            except ValueError:
                continue
            est = float(cols[i_est]) if i_est is not None and i_est < len(cols) else 0.0
            frac = (
                float(cols[i_frac]) if i_frac is not None and i_frac < len(cols) else 0.0
            )
            out[tid] = (est, frac)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--sample-type", default="sample")
    ap.add_argument("--platform", default="ont")
    ap.add_argument("--kraken-report", required=True, type=Path)
    ap.add_argument("--nanoq-raw", type=Path)
    ap.add_argument("--nanoq-filtered", type=Path)
    ap.add_argument("--l1-stats", type=Path)
    ap.add_argument("--diagnostics", type=Path)
    ap.add_argument("--bracken", type=Path, help="omit or point at a placeholder")
    ap.add_argument("--l2-stats", type=Path, help="omit or point at a placeholder")
    ap.add_argument("--out-tsv", required=True, type=Path)
    ap.add_argument("--out-json", required=True, type=Path)
    ap.add_argument("--min-reads", type=int, default=10)
    ap.add_argument("--min-rpm", type=float, default=1.0)
    ap.add_argument("--db-label", default="")
    ap.add_argument("--db-has-decoy", default="false")
    ap.add_argument("--kraken-confidence", default="")
    args = ap.parse_args()

    db_has_decoy = str(args.db_has_decoy).lower() in ("true", "1", "yes")

    rows, total_reads, unclassified = parse_kraken_report(args.kraken_report)
    host_clade = clade_reads_for(rows, 9606)
    nonhost = max(total_reads - host_clade, 0)

    l1 = read_tsv(args.l1_stats)
    l2 = read_tsv(args.l2_stats)
    diag = read_json(args.diagnostics)
    nanoq_raw = read_json(args.nanoq_raw)
    nanoq_filt = read_json(args.nanoq_filtered)
    bracken = load_bracken(args.bracken)

    # ------------------------------------------------------------------
    # Viral candidates
    # ------------------------------------------------------------------
    viral = subtree_rows(rows, VIRAL_TAXID)
    viral_total = viral[0]["clade"] if viral else 0

    # Candidates are selected by TREE POSITION, not by rank code.
    #
    # Anchoring on rank "S" looks natural and is wrong here: the custom
    # taxonomies used for phage kraken2 databases (INPHARED/ICTV, UHGV) often
    # bottom out at order-level codes such as O1, with no species node at all.
    # A rank-based rule would then find no species rows, and a sample with an
    # unmistakable phage signal would be reported as "not detected".
    #
    # Every node is counted by its DIRECT reads, so the rows sum exactly to the
    # viral clade total with no double counting. A node with children that still
    # holds reads directly is where kraken2's LCA stopped — either a read shared
    # between close relatives, or a chimera.
    for i, r in enumerate(viral):
        r["is_leaf"] = (i + 1 >= len(viral)) or (viral[i + 1]["depth"] <= r["depth"])

    candidates = []
    for r in viral:
        if r["taxid"] == VIRAL_TAXID:
            continue
        reads = r["direct"]
        if reads <= 0:
            continue

        rpm = (1e6 * reads / nonhost) if nonhost else 0.0
        pct = (100.0 * reads / nonhost) if nonhost else 0.0

        if reads < args.min_reads:
            call = "below_threshold"
        elif rpm >= args.min_rpm:
            call = "candidate_passes_abundance_screen"
        else:
            call = "candidate_low_abundance"

        flags = []
        if not db_has_decoy:
            flags.append("plasmid_mge_ambiguity_risk")
        if not r["is_leaf"]:
            flags.append("lca_stopped_above_most_specific_rank")
        if args.sample_type == "ntc":
            flags.append("negative_control_sample")

        est, frac = bracken.get(r["taxid"], ("", ""))
        candidates.append(
            {
                "taxid": r["taxid"],
                "name": r["name"],
                "rank": r["rank"],
                "is_leaf": r["is_leaf"],
                "reads": reads,
                "reads_clade": r["clade"],
                "rpm_nonhost": round(rpm, 4),
                "pct_nonhost": round(pct, 6),
                "bracken_est_reads": est,
                "bracken_fraction": frac,
                "call": call,
                "flags": flags,
            }
        )

    candidates.sort(key=lambda c: (-c["reads"], c["name"]))

    # ------------------------------------------------------------------
    # TSV
    # ------------------------------------------------------------------
    args.out_tsv.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_tsv, "w") as fh:
        fh.write(
            "sample_id\tsample_type\ttaxon_name\ttaxid\trank\tis_leaf\treads\treads_clade\t"
            "rpm_nonhost\tpct_nonhost\tnonhost_denominator\tbracken_est_reads\t"
            "bracken_fraction\tcall\tevidence\tflags\tnot_for_clinical_diagnosis\n"
        )
        if not candidates:
            fh.write(
                f"{args.sample_id}\t{args.sample_type}\tNA\tNA\tNA\tNA\t0\t0\t0\t0\t"
                f"{nonhost}\t\t\tnot_detected\tread_only\t"
                "no_taxon_passed_reporting_thresholds\tTRUE\n"
            )
        for c in candidates:
            fh.write(
                f"{args.sample_id}\t{args.sample_type}\t{c['name']}\t{c['taxid']}\t"
                f"{c['rank']}\t{str(c['is_leaf']).upper()}\t{c['reads']}\t{c['reads_clade']}\t"
                f"{c['rpm_nonhost']}\t{c['pct_nonhost']}\t{nonhost}\t"
                f"{c['bracken_est_reads']}\t{c['bracken_fraction']}\t{c['call']}\tread_only\t"
                f"{','.join(c['flags']) or 'none'}\tTRUE\n"
            )

    # ------------------------------------------------------------------
    # JSON (consumed by the run-level summary)
    # ------------------------------------------------------------------
    n_reported = sum(1 for c in candidates if c["call"] != "below_threshold")
    payload = {
        "sample_id": args.sample_id,
        "sample_type": args.sample_type,
        "platform": args.platform,
        "not_for_clinical_diagnosis": True,
        "database": {
            "label": args.db_label,
            "has_decoy": db_has_decoy,
            "kraken2_confidence": args.kraken_confidence,
        },
        "thresholds": {"min_reads": args.min_reads, "min_rpm": args.min_rpm},
        "qc": {
            "raw": nanoq_raw,
            "filtered": nanoq_filt,
        },
        "host_depletion": {
            "level1_kraken2": l1,
            "level2_minimap2": l2 or None,
            "level2_run": bool(l2),
            # False means the alignment pass did not run, so host removal
            # rests entirely on what the kraken2 database happens to
            # recognise. Output from such a run is not shareable.
            "host_depletion_complete": bool(l2),
        },
        "classification": {
            "reads_classified_total": total_reads,
            "reads_unclassified": unclassified,
            "pct_unclassified": round(100.0 * unclassified / total_reads, 4)
            if total_reads
            else 0.0,
            "host_reads_clade": host_clade,
            "nonhost_denominator": nonhost,
            "viral_reads_clade": viral_total,
            "pct_viral_of_nonhost": round(100.0 * viral_total / nonhost, 6)
            if nonhost
            else 0.0,
        },
        "chimera_diagnostics": diag,
        "bracken_run": bool(bracken),
        "n_candidates_reported": n_reported,
        "candidates": candidates,
        "caveats": [
            "Read-level evidence only: v0.1 runs no assembly, geNomad or CheckV, "
            "so no call here is confirmed by an orthogonal method.",
            "A negative result does not exclude a phage that has no close "
            "relative in the reference database: benchmark recall falls from "
            "~96% to ~50% for lineages with no >=80% ANI neighbour.",
            "Plasmids and ICE/IME share integrase and relaxase modules with "
            "temperate phages. Raising --confidence does not remove this: it "
            "filters random k-mers, not real homology. Decoy sequences in the "
            "reference database do (37.4% -> <=0.4% plasmid false positives).",
            "Precision depends on sample composition, not on the classifier.",
            "RPM is normalised to non-host reads. When that denominator is "
            "small — the norm for plasma and CSF — RPM inflates and must not be "
            "read as an absolute burden. Always read RPM next to "
            "nonhost_denominator.",
            "Read counts are not independent molecules: ONT cDNA libraries are "
            "pre-amplified, so a handful of reads can come from one template.",
            "Low-biomass plasma and CSF libraries are subject to reagent "
            "contamination; taxa seen at low abundance should be read against a "
            "no-template control from the same batch.",
            "NOT FOR CLINICAL DIAGNOSIS.",
        ],
    }
    if not db_has_decoy:
        payload["caveats"].insert(
            0,
            "This kraken2 database was declared to contain no decoy sequences "
            "(--db_has_decoy false), so the plasmid/MGE false-positive rate is "
            "the high one: expect ~37% of plasmid-derived sequence to be called "
            "phage.",
        )

    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_json, "w") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    main()
