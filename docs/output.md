# Output

```
<outdir>/
  summary/
    phamseek_report.html        read this first
    phamseek_summary.tsv        one row per sample per taxon
    phamseek_krona.html         every sample as one interactive chart
    database_manifest.tsv       which database produced these results
    pavian/                     every kraken2 report in one place, for Pavian
  <sample_id>/
    qc/                         nanoq stats, both host-depletion levels, read diagnostics
    kraken2/                    kraken2 report (and bracken output when enabled)
    krona/                      this sample's interactive chart
    clean_reads/                host-depleted FASTQ
    report/                     per-sample TSV and JSON
  pipeline_info/                execution trace, timeline, software versions
```

`clean_reads/` is written **only** when level-2 host depletion actually ran. With
`--skip_host_removal` no host-free FASTQ is produced at all, because output from such a run
cannot be shared outside the institution.

---

## How to read a call

Every row is a **candidate**. phamseek has no assembly, no geNomad and no CheckV, so nothing
here has been confirmed by an independent method. The call grade says only how far above
the reporting floor a row sits — nothing more.

| Call | Meaning |
|---|---|
| `candidate_passes_abundance_screen` | reads ≥ `--min_reads` and RPM ≥ `--min_rpm`. It passed a screen. That is not a diagnosis, and not a statement about biological abundance. |
| `candidate_low_abundance` | reads ≥ `--min_reads`, but RPM below `--min_rpm`. |
| `candidate_contamination_suspected` | It is also present in this run's no-template control. Contamination cannot be excluded. |
| `below_threshold` | Below `--min_reads`. Still printed — nothing is dropped silently. |
| `not_detected` | No taxon in the viral subtree received any reads; the sample emits this single row. This is **not** evidence of absence. |

When taxa exist but all fall below `--min_reads`, the output is a set of `below_threshold`
rows; `not_detected` does not also appear.

`candidate_contamination_suspected` is produced only in the run-level summary, because only
that step sees samples and controls together. It downgrades only rows that had already
passed the floor; `below_threshold` rows keep their call and merely gain the `also_in_ntc`
flag. The per-sample TSV keeps the row's own abundance call.

## Columns

The per-sample TSV and the run-level summary do not carry identical columns: the former has
leaf status and bracken results, the latter has the control comparison. "In" below says
which file each column appears in.

| Column | In | Notes |
|---|---|---|
| `reads` | both | Reads assigned **directly** to that node, not double-counted. The rows sum to the viral clade total minus whatever stopped directly on the Viruses root (10239) — the root itself gets no row. |
| `reads_clade` | per-sample | Reads for that node's whole clade, descendants included. |
| `rank`, `is_leaf` | `rank` both; `is_leaf` per-sample | `is_leaf=FALSE` means kraken2's LCA stopped above the most specific node this database can offer. Rank codes vary between databases; leaf status does not, which is why filtering uses the latter. |
| `rpm_nonhost` | both | Reads per million **non-host** reads. |
| `pct_nonhost` | both | The same ratio as a percentage. |
| `nonhost_denominator` | both | The denominator behind that RPM: all reads entering kraken2 minus those kraken2 placed in the *Homo sapiens* clade — the count after level 1, **not** reduced by what level-2 alignment later removed. **Always read it next to the RPM.** In plasma and CSF the non-host fraction is tiny, so RPM inflates: 191 of 700 non-host reads is 272,857 RPM, which says nothing about absolute load. |
| `ntc_enrichment` | summary | Ratio of sample RPM to control RPM, each offset by 1 RPM first. Reported only when the taxon really appears in the control, otherwise `NA`. It is background information, never a decision threshold. |
| `bracken_est_reads`, `bracken_fraction` | per-sample | bracken's re-estimated abundance. bracken is off by default, in which case both are empty. |
| `evidence` | both | Always `read_only`: no assembly tier is implemented. |
| `flags` | both | See below. |
| `not_for_clinical_diagnosis` | both | Always `TRUE`. |

## Flags

| Flag | Meaning |
|---|---|
| `plasmid_mge_ambiguity_risk` | The database has no plasmid decoy sequence. Expect roughly 37% of plasmid-derived sequence to be called phage. |
| `plasmid_decoy_unverified` | The database's plasmid decoy content could not be determined, so the false-positive rate is unknown: it could be as low as ≤0.4% or as high as ~37%. That is not the same as knowing there is none, and not the same as safe. |
| `lca_stopped_above_most_specific_rank` | Reads stopped at an internal node. Common for sequence shared between close relatives, and also produced by chimeric reads. |
| `also_in_ntc` | The taxon appears in this run's no-template control. Produced only in the run-level summary. |
| `negative_control_sample` | The row belongs to a control sample. |
| `none` | The row carries no flags. The column is never left empty. |
| `no_taxon_passed_reporting_thresholds` | Appears only on a `not_detected` row. |

## Interactive charts

Two extra views of the same kraken2 pass. Neither adds evidence: they are the numbers
already in the tables, laid out so a whole sample can be taken in at once.

### Krona

`summary/phamseek_krona.html` holds every sample as a separate dataset, switchable from
the selector at the top left; `<sample_id>/krona/<sample_id>.krona.html` is one sample on
its own. Both are self-contained — Krona inlines its JavaScript and embeds its logo — so
they open from a file manager with no network access, and they can be e-mailed as a single
file.

**They chart the non-host subtree.** The host is removed from the chart for the same
reason it is removed from the RPM denominator: in plasma and CSF around 82% of classified
reads are *Homo sapiens*, and drawing that compresses everything the chart exists to show
into a sliver too thin to click. The counts therefore reconcile with `nonhost_denominator`,
not with the total read count. The step fails rather than render a chart whose totals do
not add up.

**Look at the two categories the tables warn about.** The chart keeps every taxonomic
level, not only the seven standard ranks, so reads that stopped at `root` and reads
classified as `plasmids` both appear as their own wedges. Those are exactly the confounders
this pipeline reports on: root-level assignments are the chimera signal, and plasmid hits
are the dominant false-positive source for phage calls. A chart drawn on
`kreport2krona.py`'s default settings would drop both without saying so.

Turn the charts off with `--skip_krona`.

### Pavian

`summary/pavian/` holds a second copy of every kraken2 report, named by sample, so
[Pavian](https://github.com/fbreitwieser/pavian) can be pointed at one directory instead
of at each sample folder in turn. It is an interactive R/Shiny application, not a pipeline
step — it cannot produce a static artefact inside a workflow, and it is deliberately not in
the phamseek container, which would have to carry R and Shiny for a tool that runs outside
the workflow anyway:

```bash
cd <outdir>/summary/pavian
docker run --rm -p 5000:5000 -v "$(pwd)":/data florianbw/pavian
# then open http://localhost:5000 and load the reports from /data
```

Unlike the Krona charts, these reports are **as kraken2 wrote them** — host included,
because that is where kraken2 sits in the pipeline. Pavian's bracken panels stay empty
unless the run passed `--run_bracken`; that is this pipeline's default, not a broken
integration. The same explanation is written to `summary/pavian/README.txt`, for whoever
opens the directory without this page to hand.

## Host depletion

Two files per sample, one per level, both prefixed with the sample id.

`<sample_id>.host_removal_l1.tsv` — the kraken2 level. `host_taxid_in_db=FALSE` means the
database holds no human decoy sequence, so this level removed nothing and everything went
to level 2. That is a supported configuration, just a slower one.

`<sample_id>.host_removal_l2.tsv` — the minimap2 level. Every read that aligns to the host
reference is deleted; only reads with no alignment at all survive. minimap2 runs with
`--secondary=no`, and a supplementary alignment also disqualifies a read, so a read is
removed if any part of it aligns.

When level 1 removed a large fraction and level-2 removal is then near zero, that is the
healthy expected result: the aligner found nothing the classifier had missed.

### Known limits

Neither level can prove that zero human sequence remains. Sequence that escapes both
includes: fragments too short for either method to seed; reads that are high-error, low
complexity or from repetitive regions; human sequence too divergent from CHM13 or absent
from it entirely (population-specific insertions, structural variants, alternate
haplotypes); and chimeric reads whose human portion is small enough that the non-human part
dominates both classification and alignment.

Treat the removal counts as evidence of work done, not as proof of absence.

## Chimera diagnostics

**These are non-specific auxiliary signals. They are not a chimera rate.**

On simulated cross-domain chimeras, raising the true chimera rate to 30% moved the fraction
landing at root only from 0.16% to 0.70%. kraken2 assigns a chimeric read to whichever
segment contributed more k-mers rather than lifting the call to root, so the root fraction
cannot be read as a count of chimeric reads.

| Metric | What it indicates |
|---|---|
| `pct_at_root` | Reads kraken2 could place only at root. |
| `pct_at_internal_node` | Reads placed above the most specific node available. |
| `pct_multitaxon_kmers` | Reads whose k-mers come from two or more taxa. |
| `lift_distance_hist` | How many levels above the most specific node each read landed. `0` = on a leaf. More informative than the root fraction alone. |
| `dominant_kmer_fraction_hist` | Distribution of within-read k-mer support. Shifts left as a whole on high-error reads. |

Cross-domain chimeras do damage in **both directions**: in the same simulation, 34.7% of
phage+human chimeras were called viral (a false positive) while 62.9% were called human,
burying real phage sequence in the host pile. Chimeras between related phages are worse for
monitoring, because they **raise** the apparent viral fraction (92.7% called viral) and are
therefore invisible to any "overall percent viral" style check.

ONT artefacts are not a false-positive source: 95.9% of simulated junk and random reads
were unclassified and only 0.27% were called viral. No filter for them is needed.

## Reference database coverage

`pct_unclassified` in the per-sample JSON is an indirect indication of how well the database
covers that sample. When it is high, the limiting factor may be the database rather than the
sample.

It is only a proxy. The direct measurement — the fraction of geNomad-called viral contigs
that kraken2 leaves unclassified — needs the assembly tier, which is not implemented.

## Database manifest

`summary/database_manifest.tsv` pins down exactly which database was used: path, label,
confidence, kraken2 version, the size and mtime of each `.k2d` file, checksums of the two
small ones, and which bracken k-mer distributions are available. Any result has to be
interpreted against the database that produced it.

It also records decoy content by class:

| Key | Meaning |
|---|---|
| `db_has_decoy_declared` | The operator's declared value: `auto`, `true` or `false`. |
| `decoy_detection_method` | `kraken2-inspect`, `shipped-inspect.txt` or `unavailable`. |
| `decoy_human`, `decoy_bacterial`, `decoy_plasmid` | `detected`, `absent` or `unknown`. |
| `decoy_*_pct` | When detected, that class's share of the database's minimizers. |

They are three classes rather than one switch because they are not equally knowable: human
and bacteria have stable taxids, while "plasmid" has no single node and can only be matched
by taxid 45202 or by nodes whose name starts with `plasmid`. Only the **plasmid** class
decides the wording of the false-positive caveat, because 37.4% → ≤0.4% is a statement
about plasmids.

Detection reads the database's own taxonomy, never a sample's kraken2 report — a report
lists only taxa that received reads, so a decoy-carrying database analysing a sample with no
human reads shows no human node at all.

Declaring `false` when any decoy class is detected, or `true` when none is, produces an
explicit inconsistency warning at the top of the report, and the declaration is honoured.
The pipeline does not quietly pick a side: a confidently worded caveat built on a false
premise is worse than no caveat.

## Why a negative is not a negative

Recall depends on whether the reference database contains a near neighbour: ~96% when a
≥80% ANI neighbour exists, ~50% when it does not. Read-level figures sit 5–34 points below
contig-level ones. Precision is a function of sample composition rather than a property of
the classifier — the same database gives ~99.9% on a VLP virome and a conservative lower
bound of ~82% on a bulk metagenome.

So `not_detected` means "not detected with these settings, against this database".
