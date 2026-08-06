# Output

```
<outdir>/
  summary/
    phamseek_report.html        read this first
    phamseek_summary.tsv        every sample, every taxon, one row each
    database_manifest.tsv       which database produced these results
  <sample_id>/
    qc/                         nanoq stats, both host-depletion levels, read diagnostics
    kraken2/                    kraken2 report (+ bracken, when available)
    clean_reads/                host-depleted FASTQ
    report/                     per-sample TSV and JSON
  pipeline_info/                execution trace, timeline, software versions
```

`clean_reads/` is written **only** when level-2 host depletion ran. With
`--skip_host_removal` no host-free FASTQ is produced at all, because output from such a
run is not shareable.

---

## Reading a call

Every row is a **candidate**. v0.1 has no assembly, no geNomad and no CheckV, so nothing
is confirmed by an independent method. The call grades how far above the reporting floor a
row sits — nothing more.

| Call | Meaning |
|---|---|
| `candidate_passes_abundance_screen` | reads >= `--min_reads` and RPM >= `--min_rpm`. It passed a screen; it is not a diagnosis and not a statement about biological abundance. |
| `candidate_low_abundance` | reads >= `--min_reads`, RPM below `--min_rpm`. |
| `candidate_contamination_suspected` | Also present in a no-template control from the same run. Contamination cannot be excluded. |
| `below_threshold` | Below `--min_reads`. Still printed — nothing is silently dropped. |
| `not_detected` | No taxon reached the floor. **Not** evidence of absence. |

## Columns

| Column | Notes |
|---|---|
| `reads` | Reads assigned **directly** to this node. Rows therefore sum exactly to the viral clade total, with no double counting. |
| `rank`, `is_leaf` | `is_leaf=FALSE` means kraken2's LCA stopped above the most specific node this database offers. Rank codes vary between databases; leaf status does not, which is why selection uses it. |
| `rpm_nonhost` | Reads per million **non-host** reads. |
| `nonhost_denominator` | The denominator behind that RPM. **Always read the two together.** In plasma and CSF the non-host fraction is small, so RPM inflates: 191 reads out of 700 non-host reads is 272,857 RPM, which says nothing about absolute burden. |
| `ntc_enrichment` | Sample RPM over control RPM, both offset by 1 RPM. Reported only when the taxon actually appears in a control; `NA` otherwise. Context, never a cutoff. |
| `flags` | See below. |
| `not_for_clinical_diagnosis` | Always `TRUE`. |

## Flags

| Flag | Meaning |
|---|---|
| `plasmid_mge_ambiguity_risk` | The database has no plasmid decoy sequences. Expect roughly 37% of plasmid-derived sequence to be called phage. |
| `plasmid_decoy_unverified` | The database's plasmid decoy content could not be determined, so the false-positive rate is unknown — somewhere between ~37% and <=0.4%. Not the same as knowing there is none, and not the same as safe. |
| `lca_stopped_above_most_specific_rank` | Reads sat on an internal node. Common for sequence shared between close relatives, and also produced by chimeras. |
| `also_in_ntc` | The taxon appears in a no-template control from this run. |
| `negative_control_sample` | The row belongs to a control. |

## Host depletion

Two files per sample, one per level.

`host_removal_l1.tsv` — the kraken2 pass. `host_taxid_in_db=FALSE` means the database has
no human decoy sequences, so this level removed nothing and everything fell to level 2.
That is supported, just slower.

`host_removal_l2.tsv` — the minimap2 pass. Reads with any alignment to the host reference
are deleted; only reads with no alignment at all survive. Supplementary and secondary
alignments count, so a read whose fragment aligns is removed whole.

A level-2 removal near zero after a large level-1 removal is the expected, healthy result:
the aligner found nothing the classifier had missed.

### Known limits

Neither level can prove zero residual human sequence. Sequence that can survive both:
fragments too short for either method to seed on; error-rich, low-complexity or
repeat-derived reads; human sequence divergent from or absent in CHM13 (population-specific
insertions, structural variants, alternate haplotypes); and chimeric reads whose human
segment is small enough that the non-human portion drives both classification and
alignment. Treat the removal counts as evidence of work done, not as a proof of absence.

## Chimera diagnostics

**These are non-specific auxiliary signals. They are not a chimera rate.**

On simulated cross-domain chimeras, raising the true chimera rate to 30% moved the
root-assigned fraction only from 0.16% to 0.70%. kraken2 resolves a chimeric read toward
whichever fragment contributes more k-mers rather than lifting the call to root, so the
root fraction cannot be read as a quantity of chimeric reads.

| Metric | What it indicates |
|---|---|
| `pct_at_root` | Reads kraken2 could only place at root. |
| `pct_at_internal_node` | Reads placed above the most specific available node. |
| `pct_multitaxon_kmers` | Reads whose k-mers come from two or more taxa. |
| `lift_distance_hist` | How many levels above the most specific node each read landed. `0` = a leaf. More informative than the root fraction alone. |
| `dominant_kmer_fraction_hist` | Spread of k-mer support within each read. Left-shifted on high-error reads. |

Cross-domain chimeras do harm in **both** directions: in the same simulation 34.7% of
phage+human chimeras were called viral (false positives) while 62.9% were called human,
burying real phage sequence in the host bin. Chimeras between related phages are worse for
monitoring, because they *raise* the apparent viral fraction (92.7% called viral) and so
stay invisible to any overall viral-percentage check.

Reassuringly, ONT artifacts are not a false-positive source: simulated junk and random
reads were 95.9% unclassified, with 0.27% called viral. No filter is needed for them.

## Reference-database coverage

`pct_unclassified` in the per-sample JSON is a proxy for how well the database covers this
sample. A high value means the database, not the sample, may be the limiting factor.

It is only a proxy. The direct measurement — the fraction of contigs geNomad calls viral
that kraken2 leaves unclassified — needs the assembly tier, which v0.1 does not implement.

## Database manifest

`summary/database_manifest.tsv` pins the exact database: path, label, confidence, kraken2
version, sizes and mtimes of the `.k2d` files, checksums of the two small ones, and which
bracken k-mer distributions were available. A result is only interpretable against the
database that produced it.

It also records decoy content per class:

| Key | Meaning |
|---|---|
| `db_has_decoy_declared` | What the operator declared: `auto`, `true` or `false`. |
| `decoy_detection_method` | `kraken2-inspect`, `shipped-inspect.txt`, or `unavailable`. |
| `decoy_human`, `decoy_bacterial`, `decoy_plasmid` | `detected`, `absent` or `unknown`. |
| `decoy_*_pct` | Share of database minimizers, when detected. |

Three classes rather than one flag, because they are not equally knowable: human and
bacteria sit on stable taxids, while "plasmid" has no universal node and is matched on
taxid 45202 or a node named `plasmid*`. Only the **plasmid** class drives the
false-positive caveat, since that is what the 37.4% -> <=0.4% result is about.

Detection reads the database's own taxonomy, never a sample's kraken2 report — a report
lists only taxa that received reads, so a decoy database analysing a sample with no human
reads shows no human node at all.

When a declaration contradicts the database, the report opens with an explicit
inconsistency warning and follows the declaration. It does not silently pick a side: a
confidently worded caveat derived from a false premise is worse than no caveat.

## Why a negative is not a negative

Recall depends on the reference database containing a close neighbor: ~96% when a >=80% ANI
neighbor exists, ~50% when none does. Read-level figures sit 5-34 points below
contig-level figures. Precision is a function of sample composition, not a property of the
classifier — the same database gives ~99.9% precision on a VLP virome and a conservative
lower bound of ~82% on a bulk metagenome.

A `not_detected` therefore means "not detected under these settings, with this database".
