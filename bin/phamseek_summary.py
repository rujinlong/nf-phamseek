#!/usr/bin/env python3
"""Run-level phamseek summary: one TSV and one self-contained HTML report.

The HTML embeds all CSS inline and loads nothing from the network. That is a
hard requirement, not a style choice: this runs inside a hospital network where
the analysis host has no outbound access.

Cross-sample logic beyond concatenation: taxa that also appear in a no-template
control (`sample_type=ntc`) in the same run are flagged `also_in_ntc`. This is a
flag, not a subtraction — v0.1 does not attempt to correct abundances, because
choosing a subtraction rule needs replicate controls the pilot does not yet have.
"""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path

CALL_STYLE = {
    "candidate_passes_abundance_screen": ("call-high", "Candidate (passes abundance screen)"),
    "candidate_low_abundance": ("call-low", "Candidate (low abundance)"),
    "candidate_contamination_suspected": (
        "call-warn",
        "Candidate - also in NTC, contamination cannot be excluded",
    ),
    "below_threshold": ("call-below", "Below reporting threshold"),
    "not_detected": ("call-none", "Not detected under these settings"),
}

# Added to both sample and control RPM before dividing, so a taxon absent from
# the control does not produce a division by zero or an unbounded ratio.
NTC_PSEUDOCOUNT_RPM = 1.0


def load_samples(paths):
    out = []
    for p in sorted(paths):
        with open(p) as fh:
            out.append(json.load(fh))
    return out


def ntc_profile(samples):
    """(has_ntc, taxid -> highest RPM seen in any no-template control).

    Every control row counts, including ones below the reporting floor: a taxon
    that is barely visible in the control is exactly the one most likely to be
    reagent background in the sample.
    """
    has_ntc = any(s.get("sample_type") == "ntc" for s in samples)
    rpm = {}
    for s in samples:
        if s.get("sample_type") != "ntc":
            continue
        for c in s.get("candidates", []):
            rpm[c["taxid"]] = max(rpm.get(c["taxid"], 0.0), float(c["rpm_nonhost"]))
    return has_ntc, rpm


def ntc_enrichment(sample_rpm, ntc_rpm):
    """Sample RPM over control RPM, both offset by a pseudocount.

    Only defined when the taxon was actually seen in the control. For a taxon
    absent from the control the ratio would just restate the sample's own RPM,
    and against the inflated RPM values that a small non-host denominator
    produces it would print as a five-figure "enrichment" that means nothing
    more than "not in the control" — an artefact that reads as strong evidence.
    Those rows report NA and rely on the absence of the also_in_ntc flag.

    Reported as context, never applied as a cutoff: NTC subtraction removes
    genuine signal and assumes the control and the sample were contaminated to
    the same degree, which no one has shown for this assay.
    """
    return (float(sample_rpm) + NTC_PSEUDOCOUNT_RPM) / (
        float(ntc_rpm) + NTC_PSEUDOCOUNT_RPM
    )


def annotate(c, sample_type, has_ntc, ntc_rpm):
    """Return (call, flags, enrichment_or_None) for one candidate row."""
    flags = list(c["flags"])
    call = c["call"]
    enr = None
    if has_ntc and sample_type != "ntc" and c["taxid"] in ntc_rpm:
        enr = ntc_enrichment(c["rpm_nonhost"], ntc_rpm[c["taxid"]])
        flags.append("also_in_ntc")
        if call != "below_threshold":
            call = "candidate_contamination_suspected"
    return call, flags, enr


def fmt(v, nd=2):
    if v in (None, ""):
        return "&ndash;"
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return html.escape(str(v))


def bar(pct, cls="bar-fill"):
    pct = max(0.0, min(100.0, float(pct or 0.0)))
    return (
        f'<div class="bar"><div class="{cls}" style="width:{pct:.2f}%"></div></div>'
        f'<span class="bar-label">{pct:.2f}%</span>'
    )


def histogram_svg(hist, edges, width=420, height=110):
    """Bar chart from a count list.

    `edges` may be either n+1 bin boundaries (a continuous axis) or n labels (a
    discrete axis); the tooltip adapts, so indexing never runs past the end.
    """
    if not hist or not any(hist):
        return '<p class="muted">No classified reads to summarise.</p>'
    n = len(hist)
    continuous = len(edges) > n

    def bin_label(i):
        if continuous:
            return f"{edges[i]}-{edges[i + 1]}"
        return str(edges[i]) if i < len(edges) else str(i)

    top = max(hist)
    bw = width / n
    bars = []
    for i, v in enumerate(hist):
        h = (v / top) * (height - 24) if top else 0
        x = i * bw
        y = height - 18 - h
        bars.append(
            f'<rect x="{x + 1:.1f}" y="{y:.1f}" width="{bw - 2:.1f}" height="{h:.1f}" '
            f'class="hbar"><title>{bin_label(i)}: {v} reads</title></rect>'
        )
    step = 2 if continuous else 1
    ticks = "".join(
        f'<text x="{i * bw + bw/2:.1f}" y="{height - 4}" class="tick">{bin_label(i) if not continuous else edges[i]}</text>'
        for i in range(0, n, step)
    )
    return (
        f'<svg viewBox="0 0 {width} {height}" class="hist" role="img" '
        f'aria-label="Distribution of dominant k-mer fraction per read">'
        f'{"".join(bars)}{ticks}</svg>'
    )


def write_tsv(samples, has_ntc, ntc_rpm, out_path: Path):
    with open(out_path, "w") as fh:
        fh.write(
            "sample_id\tsample_type\ttaxon_name\ttaxid\trank\treads\trpm_nonhost\t"
            "pct_nonhost\tnonhost_denominator\tntc_enrichment\tcall\tevidence\tflags\t"
            "not_for_clinical_diagnosis\n"
        )
        for s in samples:
            sid, stype = s["sample_id"], s.get("sample_type", "sample")
            denom = (s.get("classification") or {}).get("nonhost_denominator", "")
            cands = s.get("candidates", [])
            if not cands:
                fh.write(
                    f"{sid}\t{stype}\tNA\tNA\tNA\t0\t0\t0\t{denom}\tNA\t"
                    "not_detected\tread_only\t"
                    "no_taxon_passed_reporting_thresholds\tTRUE\n"
                )
                continue
            for c in cands:
                call, flags, enr = annotate(c, stype, has_ntc, ntc_rpm)
                enr_s = f"{enr:.2f}" if enr is not None else "NA"
                fh.write(
                    f"{sid}\t{stype}\t{c['name']}\t{c['taxid']}\t{c['rank']}\t"
                    f"{c['reads']}\t{c['rpm_nonhost']}\t{c['pct_nonhost']}\t{denom}\t"
                    f"{enr_s}\t{call}\tread_only\t{','.join(flags) or 'none'}\tTRUE\n"
                )


CSS = """
:root{--fg:#1a1d21;--bg:#fff;--muted:#666;--line:#e2e5e9;--accent:#2b6cb0;
--warn:#b7791f;--warnbg:#fffaf0;--high:#2f855a;--low:#b7791f;--none:#718096;--card:#f7f9fb}
*{box-sizing:border-box}
body{margin:0;padding:2rem 1.25rem;font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--fg);background:var(--bg)}
.wrap{max-width:1080px;margin:0 auto}
h1{font-size:1.6rem;margin:0 0 .25rem}
h2{font-size:1.15rem;margin:2.25rem 0 .75rem;padding-bottom:.35rem;border-bottom:2px solid var(--line)}
h3{font-size:1rem;margin:1.5rem 0 .5rem}
.sub{color:var(--muted);margin:0 0 1.5rem}
.banner{background:var(--warnbg);border:1px solid #f6e05e;border-left:4px solid var(--warn);
padding:.85rem 1rem;border-radius:4px;margin:1rem 0 1.75rem}
.banner strong{color:var(--warn)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:.75rem;margin:.75rem 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:.75rem .9rem}
.card .k{font-size:.75rem;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}
.card .v{font-size:1.35rem;font-weight:600;margin-top:.15rem}
.card .n{font-size:.78rem;color:var(--muted)}
.tablewrap{overflow-x:auto;border:1px solid var(--line);border-radius:6px}
table{border-collapse:collapse;width:100%;font-size:.88rem}
th,td{padding:.5rem .65rem;text-align:left;border-bottom:1px solid var(--line);white-space:nowrap}
th{background:var(--card);font-weight:600;position:sticky;top:0}
tr:last-child td{border-bottom:none}
.tag{display:inline-block;padding:.1rem .45rem;border-radius:10px;font-size:.75rem;font-weight:600}
.call-high{background:#c6f6d5;color:var(--high)}
.call-low{background:#fefcbf;color:var(--low)}
.call-warn{background:#fed7d7;color:#9b2c2c}
.call-below{background:#edf2f7;color:var(--none)}
.call-none{background:#edf2f7;color:var(--none)}
.flag{display:inline-block;background:#fed7d7;color:#9b2c2c;border-radius:3px;padding:.05rem .35rem;font-size:.72rem;margin-right:.2rem}
.flag.info{background:#bee3f8;color:#2a4365}
.bar{display:inline-block;width:110px;height:9px;background:#edf2f7;border-radius:5px;overflow:hidden;vertical-align:middle}
.bar-fill{height:100%;background:var(--accent)}
.bar-host{height:100%;background:#805ad5}
.bar-label{font-size:.78rem;color:var(--muted);margin-left:.4rem}
.muted{color:var(--muted);font-size:.88rem}
ul.caveats{font-size:.88rem;color:#2d3748;padding-left:1.1rem}
ul.caveats li{margin:.3rem 0}
.hist{width:100%;max-width:440px;height:auto}
.hbar{fill:var(--accent);opacity:.8}
.tick{font-size:9px;fill:var(--muted);text-anchor:middle}
code{background:var(--card);padding:.1rem .3rem;border-radius:3px;font-size:.85em}
@media (prefers-color-scheme:dark){
:root{--fg:#e6e9ed;--bg:#15181c;--muted:#9aa4b0;--line:#2c323a;--card:#1c2026;--warnbg:#2a2417}
th{background:#1c2026}
.call-high{background:#22543d;color:#9ae6b4}.call-low{background:#453411;color:#f6e05e}
.call-warn{background:#4a1d1d;color:#feb2b2}
.call-below,.call-none{background:#2c323a;color:#a0aec0}
.flag{background:#4a1d1d;color:#feb2b2}.flag.info{background:#1a365d;color:#bee3f8}
.bar{background:#2c323a}ul.caveats li{color:#cbd5e0}
}
"""


def render_html(samples, has_ntc, ntc_rpm, run_meta, out_path: Path):
    parts = [f"<title>phamseek report</title><style>{CSS}</style>", '<div class="wrap">']
    parts.append("<h1>phamseek &mdash; phage detection report</h1>")
    parts.append(
        f'<p class="sub">{len(samples)} sample(s) &middot; pipeline '
        f'{html.escape(run_meta.get("version", "0.1.0"))} &middot; mode '
        f'<code>{html.escape(run_meta.get("mode", "fast"))}</code> &middot; database '
        f'<code>{html.escape(run_meta.get("db_label") or "unlabelled")}</code></p>'
    )
    parts.append(
        '<div class="banner"><strong>NOT FOR CLINICAL DIAGNOSIS.</strong> '
        "v0.1 reports read-level k-mer evidence only &mdash; no assembly, no geNomad, "
        "no CheckV. Every positive row below is a <em>candidate</em> requiring "
        "orthogonal confirmation (targeted mapping, PCR, or sequencing of a "
        "second aliquot). A negative result does not exclude a phage that has no "
        "close relative in the reference database.</div>"
    )

    if has_ntc:
        parts.append(
            '<p class="muted">A no-template control is present in this run. Taxa also '
            "seen in it are flagged <span class='flag'>also_in_ntc</span> and their call "
            "is downgraded. The <em>vs NTC</em> column is sample RPM over control RPM, "
            f"both offset by {NTC_PSEUDOCOUNT_RPM:g} RPM; it is context, not a cutoff. "
            "phamseek does <strong>not</strong> subtract control counts, because "
            "subtraction removes genuine signal and assumes both libraries were "
            "contaminated to the same degree.</p>"
        )
        power = [
            f'{html.escape(x["sample_id"])} ({fmt((x.get("classification") or {}).get("nonhost_denominator"))} non-host reads)'
            for x in samples
            if x.get("sample_type") == "ntc"
        ]
        parts.append(
            '<p class="muted">Control detection power: ' + ", ".join(power) + ". "
            "A control with few or no non-host reads cannot exonerate a taxon; "
            "absence of the <span class='flag'>also_in_ntc</span> flag then says "
            "little.</p>"
        )
    else:
        parts.append(
            '<p class="muted">No no-template control in this run. In low-biomass '
            "plasma and CSF libraries, reagent contamination is a leading cause of "
            "low-abundance calls; a batch-matched NTC is strongly recommended.</p>"
        )

    # ---------------- per-sample ----------------
    for s in samples:
        sid = html.escape(s["sample_id"])
        stype = html.escape(s.get("sample_type", "sample"))
        cls = s.get("classification", {})
        hd = s.get("host_depletion", {})
        l1 = hd.get("level1_kraken2") or {}
        l2 = hd.get("level2_minimap2") or {}
        qc_raw = (s.get("qc") or {}).get("raw") or {}
        qc_filt = (s.get("qc") or {}).get("filtered") or {}
        diag = s.get("chimera_diagnostics") or {}

        parts.append(f"<h2>{sid} <span class='muted'>({stype})</span></h2>")

        parts.append('<div class="grid">')
        parts.append(
            f'<div class="card"><div class="k">Reads after QC</div>'
            f'<div class="v">{fmt(qc_filt.get("reads"))}</div>'
            f'<div class="n">from {fmt(qc_raw.get("reads"))} raw &middot; N50 '
            f'{fmt(qc_filt.get("n50"))} bp</div></div>'
        )
        parts.append(
            f'<div class="card"><div class="k">Host removed (L1 kraken2)</div>'
            f'<div class="v">{fmt(float(l1.get("host_removed_l1_pct", 0) or 0))}%</div>'
            f'<div class="n">{fmt(l1.get("host_reads_removed_l1"))} reads deleted</div></div>'
        )
        if hd.get("level2_run"):
            parts.append(
                f'<div class="card"><div class="k">Host removed (L2 minimap2)</div>'
                f'<div class="v">{fmt(float(l2.get("host_removed_l2_pct", 0) or 0))}%</div>'
                f'<div class="n">{fmt(l2.get("host_reads_removed_l2"))} of '
                f'{fmt(l2.get("reads_to_l2"))} reads</div></div>'
            )
        else:
            parts.append(
                '<div class="card"><div class="k">Host removed (L2)</div>'
                '<div class="v">skipped</div><div class="n">--skip_host_removal was set; '
                "alignment-level host depletion did not run</div></div>"
            )
        parts.append(
            f'<div class="card"><div class="k">Unclassified</div>'
            f'<div class="v">{fmt(cls.get("pct_unclassified"))}%</div>'
            f'<div class="n">reference-coverage proxy</div></div>'
        )
        parts.append(
            f'<div class="card"><div class="k">Non-host denominator</div>'
            f'<div class="v">{fmt(cls.get("nonhost_denominator"))}</div>'
            f'<div class="n">RPM base; small values inflate RPM</div></div>'
        )
        parts.append("</div>")

        if str(l1.get("host_taxid_in_db", "")).upper() == "FALSE":
            parts.append(
                '<div class="banner">This kraken2 database contains no human decoy '
                "sequence, so level-1 host depletion removed nothing and all host "
                "removal fell to the aligner. Detection is unaffected; throughput is."
                "</div>"
            )

        # candidates table
        cands = s.get("candidates", [])
        parts.append("<h3>Viral candidates</h3>")
        if not cands:
            parts.append(
                '<p><span class="tag call-none">Not detected under these settings</span> '
                '<span class="muted">No viral taxon reached the reporting floor. This is '
                "not evidence of absence.</span></p>"
            )
        else:
            parts.append('<div class="tablewrap"><table><thead><tr>')
            for h in (
                "Taxon",
                "TaxID",
                "Rank",
                "Reads",
                "RPM (non-host)",
                "vs NTC",
                "Call",
                "Flags",
            ):
                parts.append(f"<th>{h}</th>")
            parts.append("</tr></thead><tbody>")
            for c in cands:
                call, flags, enr = annotate(c, stype, has_ntc, ntc_rpm)
                style, label = CALL_STYLE.get(call, ("call-none", call))
                enr_s = f"{enr:.1f}x" if enr is not None else "&ndash;"
                fhtml = (
                    "".join(
                        f'<span class="flag{" info" if f.startswith("lca_stopped") else ""}">'
                        f"{html.escape(f)}</span>"
                        for f in flags
                    )
                    or '<span class="muted">&ndash;</span>'
                )
                parts.append(
                    f'<tr><td>{html.escape(c["name"])}</td><td>{c["taxid"]}</td>'
                    f'<td>{html.escape(c["rank"])}</td><td>{c["reads"]}</td>'
                    f'<td>{fmt(c["rpm_nonhost"])}</td><td>{enr_s}</td>'
                    f'<td><span class="tag {style}">{html.escape(label)}</span></td>'
                    f"<td>{fhtml}</td></tr>"
                )
            parts.append("</tbody></table></div>")

        # chimera diagnostics
        parts.append("<h3>Chimera diagnostics</h3>")
        parts.append(
            '<div class="banner"><strong>These are non-specific auxiliary signals, '
            "not a chimera rate.</strong> On simulated cross-domain chimeras, raising "
            "the chimera rate to 30% moved the root-assigned fraction only from 0.16% "
            "to 0.70%: kraken2 resolves a chimeric read towards whichever fragment "
            "contributes more k-mers instead of lifting it to root. Read these as "
            "&quot;something about this library looks unusual&quot;, never as a "
            "quantity of chimeric reads.</div>"
        )
        parts.append(
            '<p class="muted">ONT cDNA libraries produce concatemers, both '
            "ligation-derived and spacer-joined after pre-amplification. Cross-domain "
            "chimeras do harm in <strong>both</strong> directions: in the same "
            "simulation 34.7% of phage+human chimeras were called viral (false "
            "positives) while 62.9% were called human, burying genuine phage sequence "
            "in the host bin. Chimeras between related phages are worse still for "
            "monitoring, because they <em>raise</em> the apparent viral fraction "
            "(92.7% called viral) and so hide the problem from any overall viral-percentage "
            "check. v0.1 measures; it does not split chimeric reads.</p>"
        )
        parts.append('<div class="grid">')
        for key, lbl in (
            ("pct_at_root", "Assigned to root"),
            ("pct_at_internal_node", "LCA stopped at an internal node"),
            ("pct_multitaxon_kmers", "Reads with k-mers from &ge;2 taxa"),
        ):
            parts.append(
                f'<div class="card"><div class="k">{lbl}</div>'
                f'<div class="v">{fmt(diag.get(key))}%</div></div>'
            )
        parts.append("</div>")
        parts.append(
            "<p class='muted'>Distribution of the dominant k-mer fraction per read "
            f"(mean {fmt(diag.get('mean_dominant_kmer_fraction'))}). A left-shifted "
            "distribution means reads whose k-mers are split across taxa.</p>"
        )
        parts.append(
            histogram_svg(
                diag.get("dominant_kmer_fraction_hist"),
                diag.get("hist_bin_edges", [i / 10 for i in range(11)]),
            )
        )
        parts.append(
            "<p class='muted'>Lift distance: how many levels above the most specific "
            "available node each read was placed. 0 means a leaf, i.e. as specific as "
            "this database allows. This carries more information than the root fraction "
            "alone, because an LCA that stops one or two levels short is the common "
            "outcome for both shared and chimeric reads.</p>"
        )
        parts.append(
            histogram_svg(
                diag.get("lift_distance_hist"),
                diag.get("lift_distance_bin_labels", ["0", "1", "2", "3", "4", "5+"]),
            )
        )

    # ---------------- caveats ----------------
    parts.append("<h2>How to read this report</h2><ul class='caveats'>")
    seen = set()
    for s in samples:
        for c in s.get("caveats", []):
            if c not in seen:
                seen.add(c)
                parts.append(f"<li>{html.escape(c)}</li>")
    parts.append("</ul>")
    parts.append(
        '<p class="muted">Methodological basis: benchmark of kraken2-based '
        "in-silico phage detection (p0126-kraken2phage). Detection depends on the "
        "reference database containing a close neighbour; decoy sequences, not "
        "confidence thresholds, control plasmid and MGE false positives.</p>"
    )
    parts.append("</div>")

    out_path.write_text("\n".join(parts), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", nargs="+", required=True, type=Path)
    ap.add_argument("--out-tsv", required=True, type=Path)
    ap.add_argument("--out-html", required=True, type=Path)
    ap.add_argument("--version", default="0.1.0")
    ap.add_argument("--mode", default="fast")
    ap.add_argument("--db-label", default="")
    args = ap.parse_args()

    samples = load_samples(args.json)
    has_ntc, ntc_rpm = ntc_profile(samples)
    write_tsv(samples, has_ntc, ntc_rpm, args.out_tsv)
    render_html(
        samples,
        has_ntc,
        ntc_rpm,
        {"version": args.version, "mode": args.mode, "db_label": args.db_label},
        args.out_html,
    )


if __name__ == "__main__":
    main()
