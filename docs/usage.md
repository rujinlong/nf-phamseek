# Usage

## Installation

```bash
bin/phamseek install     # resolves the locked environment; no root required
bin/phamseek doctor      # confirms every tool is present and reports plugin cache status
```

`pixi` is a single static binary. It installs into `.pixi/` inside this repository and does
not modify or interact with an existing conda installation. For hosts without network
access see [../deploy/INSTALL.md](../deploy/INSTALL.md).

## Running

```bash
bin/phamseek run \
    --input samplesheet.csv \
    --db_dir /path/to/phamseek_db \
    --db_has_decoy \
    --db_label uhgv_inphared_decoy_2026-04 \
    --outdir results
```

Add `--resume` to continue an interrupted run instead of restarting it. Add `-stub` to
walk the wiring without executing any tool.

`bin/phamseek run --help` prints every parameter with its default and help text.

## Samplesheet

CSV with a header row.

| Column | Required | Default | Notes |
|---|---|---|---|
| `sample_id` | yes | — | Unique, no whitespace. Becomes the output directory name. |
| `fastq` | yes | — | Absolute, or relative to the samplesheet's own directory. `.fastq`/`.fq`, optionally `.gz`. |
| `platform` | no | `ont` | Only `ont` is implemented in v0.1. |
| `sample_type` | no | `sample` | One of `sample`, `ntc`, `positive_control`. |

```csv
sample_id,fastq,platform,sample_type
plasma_01,reads/plasma_01.fastq.gz,ont,sample
csf_02,/data/run17/csf_02.fastq.gz,ont,sample
ntc_01,reads/ntc_01.fastq.gz,ont,ntc
```

The samplesheet is validated before any work starts. Each file is checked for existence,
readability, non-zero size, a plausible extension, and — for `.gz` files — a real gzip
magic number, so a truncated or mislabeled file fails immediately rather than three steps
in.

### Controls

Mark no-template controls `ntc`. phamseek then flags every taxon that also appears in a
control, downgrades its call to `candidate_contamination_suspected`, and reports how much
detection power the control actually had. It never subtracts control counts.

A control with few or no non-host reads cannot exonerate anything, and the report says so.

## Databases

```
<db_dir>/kraken2/    hash.k2d, opts.k2d, taxo.k2d  (+ optional database<N>mers.kmer_distrib)
<db_dir>/host/       chm13v2.mmi                   (or any *.mmi / FASTA)
```

Override either independently with `--kraken2_db` and `--host_index`.

Building the host index — the preset must match the one used at mapping time:

```bash
minimap2 -x map-ont -I 8G -t 16 -d <db_dir>/host/chm13v2.mmi chm13v2.fna.gz
```

`bracken` needs `database<N>mers.kmer_distrib` files inside the kraken2 database. When they
are absent phamseek warns, skips bracken, and records the fact in
`summary/database_manifest.tsv`. Note that bracken's model assumes a fixed read length,
which fits ONT data poorly; kraken2 read counts are the primary abundance measure here.

## Key parameters

| Parameter | Default | Notes |
|---|---|---|
| `--mode` | `fast` | `full` (assembly tier) is not implemented in v0.1 and fails with an explanation. |
| `--kraken2_confidence` | `0.02` | Not kraken2's default of 0. At 0 a single k-mer hit calls a taxon, which made 61% of human and 38% of clean bacterial contigs look like phage. Raising it further does not remove plasmid/MGE false positives. |
| `--db_has_decoy` | off | Declare that the database contains non-phage decoy sequences. Cannot be detected automatically; changes how the report words its false-positive caveat. |
| `--min_reads` | `10` | Reporting floor. Rows below it are still printed, marked `below_threshold`. |
| `--min_rpm` | `1.0` | Per million **non-host** reads. |
| `--chopper_min_quality` | `10` | Mean Phred per read. |
| `--chopper_min_length` | `200` | Minimum read length. |
| `--skip_host_removal` | off | Skips level 2 only. See the warning below. |
| `--l2_input` | `all_nonhuman` | `nonhuman_nonviral` withholds viral reads from the aligner: marginally faster, but a human read misclassified as viral would then escape host depletion. |
| `--max_memory` | `128.GB` | Must exceed the kraken2 database size. |
| `--max_cpus` | `16` | |

### `--skip_host_removal`

This disables the **alignment** pass only; the kraken2 level-1 pass always runs. Host
removal then rests entirely on what the database happens to recognize, and no host-free
FASTQ is published at all. Output from such a run must not leave the institution. The
option exists for development and for debugging database coverage, not for production.

## Resources

kraken2 loads the whole database into RAM, so `phamseek` runs at most one kraken2 task at
a time (`maxForks 1`). Running them in parallel would multiply the memory requirement and
would not be faster: the second sample hits the page cache instead of re-reading the
database from disk, and classification itself is not the bottleneck.

Raise `--max_memory` above your database size. An 11 GB database peaks around 12 GB.

## Offline operation

Everything except two steps is offline:

1. `pixi install` downloads packages the first time.
2. Nextflow downloads its `nf-validation` plugin into `$NXF_HOME/plugins` on first run.

`bin/phamseek doctor` reports whether the plugin is cached. Once it is, `bin/phamseek`
sets `NXF_OFFLINE=true` automatically. See [../deploy/INSTALL.md](../deploy/INSTALL.md) for
pre-staging both on a networked machine.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `unable to find kraken2 in $KRAKEN2_DB_PATH` | An inherited `KRAKEN2_DB_PATH` from your shell profile. phamseek unsets it and passes absolute paths; if you see this, you are calling kraken2 outside the pipeline. |
| `kraken2 database ... is incomplete` | The directory is missing `hash.k2d`, `opts.k2d` or `taxo.k2d`. |
| `No host reference (*.mmi or FASTA) found` | Build the index, or pass `--skip_host_removal` and accept the consequence above. |
| `expected N field(s) from the report join` | A Nextflow version change altered `join(remainder: true)` padding. The run stops rather than building a report from possibly mismatched files. |
| `expected reports for N sample(s) but found M` | A sample was dropped between classification and reporting; the summary refuses to emit a partial run. |
| `read order mismatch at record N` | kraken2 stopped preserving input order, which would make the streaming host split unsafe. The run stops. |
