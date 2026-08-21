# Usage

## Installation

You need [Nextflow](https://www.nextflow.io) (`>=24.04.0`) and one source of software.
Nextflow fetches the pipeline itself:

```bash
nextflow pull rujinlong/nf-phamseek     # or git clone and run inside the checkout
```

Pick the software source with `-profile`:

| profile | software comes from | prerequisite |
|---|---|---|
| *(none)* / `apptainer` | **the default**. Multi-arch image `docker.io/jinlongru/nf-phamseek:v0.1.0` | apptainer installed |
| `docker` | the same image | docker installed |
| `singularity`, `podman` | the same image | that engine installed |
| `pixi` | the locked conda environment in the repository's `.pixi/` | run `pixi install --frozen` once |
| `nocontainer` | whatever is already on `PATH` | you guarantee the tools are there |

pixi is a single static binary. It installs into `.pixi/` inside the repository and neither
modifies nor interferes with an existing conda installation. For hosts without network
access see [../deploy/INSTALL.md](../deploy/INSTALL.md).

Nextflow has no native pixi support. The `process.pixi` directive was proposed in
[nextflow-io/nextflow#6157](https://github.com/nextflow-io/nextflow/pull/6157), closed in
favour of a general `package` directive
([#6342](https://github.com/nextflow-io/nextflow/pull/6342)), and that closed too when the
effort stalled in February 2026. `-profile pixi` therefore activates through
`beforeScript` + `pixi shell-hook`, which also picks up `LD_LIBRARY_PATH` and the other
activation variables that merely prepending `bin/` to `PATH` would miss.

## Running

```bash
nextflow run rujinlong/nf-phamseek \
    -profile apptainer \
    --input samplesheet.csv \
    --db_dir /path/to/phamseek_db \
    --db_label inphared_decoy_2026-04 \
    --outdir results
```

`-resume` continues from where a run stopped instead of restarting it. `-stub` walks the
wiring without executing any tool (pair it with `-profile nocontainer`, or you pull a 5 GB
image in order to run `touch`).

Every parameter, with its default, is under [Key parameters](#key-parameters) below.

> **`--help` is currently broken on Nextflow 26.04+**, and not by this pipeline. Under
> Nextflow's strict parser a bare `--help` arrives as the String `"true"` rather than a
> boolean, and nf-validation reads any string as "show help for the parameter with this
> name" — so it fails with `Specified param 'true' does not exist in JSON schema`. The same
> is true of nf-schema 2.1–2.4, so it is not fixed by changing plugin. Until the pipeline
> migrates to the plugin's config-driven help, use this table, or
> `NXF_SYNTAX_PARSER=v1 nextflow run rujinlong/nf-phamseek --help`.

> `-profile`, `-resume` and `-stub` are **Nextflow's own** options and take one dash;
> `--input`, `--db_dir` and the rest are pipeline parameters and take two. Getting this
> backwards makes Nextflow treat the option as an unknown pipeline parameter rather than
> report the mistake.

## Samplesheet

A CSV with a header row.

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

Every row is validated before anything runs. Each file is checked for existence,
readability, non-zero size and a plausible extension, and a `.gz` file has its first two
bytes compared against the gzip magic number — so a mislabelled extension, or a file
already corrupt at the front, fails immediately rather than several steps in. (That check
reads the header only. A gzip truncated at the *end* fails later, when a tool reaches it.)

`sample_type` selects how the report treats the row, not what the material was: plasma and
CSF are both `sample`.

### Controls

Label a no-template control `ntc`. phamseek flags every taxon that also appears in the
control with `also_in_ntc`, downgrades those rows that had passed the reporting floor to
`candidate_contamination_suspected` (rows already `below_threshold` are left alone), and
reports how much detection power that control actually had. It never subtracts control
counts.

A control with few or no non-host reads cannot clear any taxon of suspicion, and the
report says so.

## Databases

```
<db_dir>/kraken2/    hash.k2d, opts.k2d, taxo.k2d  (+ optional database<N>mers.kmer_distrib)
<db_dir>/host/       chm13v2.mmi                   (or any *.mmi / FASTA)
```

Either can be overridden individually with `--kraken2_db` and `--host_index`.

### Getting a prebuilt pair in one command

```bash
nextflow run rujinlong/nf-phamseek --mode setup --db_dir /data/phamseek_db
nextflow run rujinlong/nf-phamseek --mode setup --db_dir /data/phamseek_db --db_component host
```

`--mode setup` downloads the databases and stops; it reads no samplesheet and needs no
`--input`. It also needs no `-profile`: the download step declares no container, so
fetching a database does not first require pulling a 1.6 GB image. What it does need on
the host is `curl`, `tar` and `zstd`.

8.5 GB downloaded, ~16 GB on disk once unpacked. Downloads resume after an interruption,
every archive is checked against a pinned SHA-256 before it is unpacked, and re-running
skips whatever is already in place. You get `inphared_decoy` (INPHARED-derived, carrying
human, bacterial and plasmid decoy sequence) and a `map-ont` minimap2 index of T2T-CHM13v2.

The same thing exists as a standalone script for machines that do not have Nextflow yet:

```bash
curl -fsSLO https://raw.githubusercontent.com/rujinlong/nf-phamseek/main/deploy/fetch_db.sh
bash fetch_db.sh --outdir /data/phamseek_db
```

**The download is never automatic.** An analysis run that cannot find its database stops
and prints the `--mode setup` command that would fix it. It does not start an 8.5 GB
transfer because a path was mistyped, and it does not decide on your behalf that
`inphared_decoy` suits your samples.

Build your own whenever your target niche differs — **that choice affects results more
than any other parameter in the pipeline.**

Building a host index — the preset must match the one used for mapping:

```bash
minimap2 -x map-ont -I 8G -t 16 -d <db_dir>/host/chm13v2.mmi chm13v2.fna.gz
```

### bracken

bracken is off by default (`--skip_bracken` defaults to `true`) because its model assumes
one fixed read length, which ONT violates by construction. kraken2 read counts and the RPM
derived from them are reported either way and do not depend on it.

To enable it you must also give `--bracken_read_length`, the median read length of your own
run (nanoq reports it), or the pipeline stops immediately: no defensible default exists
across ONT runs, and a wrong `-r` produces numbers that look reasonable and are not.

```bash
nextflow run rujinlong/nf-phamseek -profile apptainer \
    --skip_bracken false --bracken_read_length 1400 \
    --input samplesheet.csv --db_dir <db> --outdir results
```

Even when enabled, bracken needs `database<N>mers.kmer_distrib` files inside the kraken2
database. When they are missing phamseek warns, skips bracken, and records that in
`summary/database_manifest.tsv`.

## Key parameters

| Parameter | Default | Notes |
|---|---|---|
| `--mode` | `fast` | `setup` downloads the reference databases and stops. `full` (the assembly tier) is not implemented in v0.1 and fails with an explanation. |
| `--kraken2_confidence` | `0.02` | Not kraken2's own default of 0. At 0 a single k-mer hit is enough to call a taxon, which made 61% of human and 38% of clean bacterial contigs look like phage. Raising it further will not remove plasmid/MGE false positives. |
| `--db_component` | `all` | With `--mode setup` only: `all`, `kraken2` or `host`. |
| `--db_has_decoy` | `auto` | `auto` reads the database's own taxonomy and reports human, bacterial and plasmid decoys separately. A declaration of `false` when any class is detected, or `true` when none is, produces an explicit inconsistency warning in the report. All three values can be given on the command line. |
| `--min_reads` | `10` | Reporting floor. Rows below it are still printed, marked `below_threshold`. |
| `--min_rpm` | `1.0` | Per million **non-host** reads. |
| `--chopper_min_quality` | `10` | Mean Phred per read. |
| `--chopper_min_length` | `200` | Minimum read length. |
| `--skip_bracken` | `true` | Off by default, see above. Setting it `false` requires `--bracken_read_length`. |
| `--bracken_read_length` | none | Used only when bracken is on, and then mandatory. The median read length of your run. |
| `--skip_host_removal` | off | Skips level 2 only. See the warning below. |
| `--l2_input` | `all_nonhuman` | `nonhuman_nonviral` lets viral reads bypass the aligner: slightly faster, but a human read misclassified as viral then escapes host depletion. |
| `--max_memory` | `128.GB` | Must exceed the kraken2 database size. |
| `--max_cpus` | `16` | |

### About `--db_has_decoy`

A three-state parameter: `auto` (default), `true` or `false`. All three work on the command
line.

Leave it at `auto` in almost every case. It reads the database's own taxonomy with
`kraken2-inspect`, which is more reliable than a human declaration, and a class it cannot
detect is reported as `unknown` and flagged rather than guessed. Declare a value explicitly
only when your database organises taxids unconventionally and `auto` cannot see them.

### `--skip_host_removal`

It disables the **alignment** level only; the kraken2 level-1 pass always runs. Host
depletion then depends entirely on what the database happens to recognise, and no host-free
FASTQ is published at all. Output from such a run must not leave the institution. The
option exists for development and for diagnosing database coverage, not for production.

## Resources

kraken2 loads the entire database into RAM, so phamseek runs at most one kraken2 task at a
time (`maxForks 1`). Running them in parallel multiplies the memory requirement and is not
faster: later samples hit the page cache instead of re-reading the database from disk, and
classification is not the bottleneck anyway.

Set `--max_memory` above the database size. An 11 GB database peaks around 12 GB.

## Running offline

Everything is offline except these:

1. `pixi install` downloads packages the first time (only needed for `-profile pixi`).
2. Nextflow downloads the `nf-validation` plugin into `$NXF_HOME/plugins` on first run.
3. With a container profile, the first run pulls the image from Docker Hub and converts it
   to a SIF.

Once all three are cached, `NXF_OFFLINE=true` makes the run fully offline. For preparing
them on a networked machine see [../deploy/INSTALL.md](../deploy/INSTALL.md); the offline
bundle points `NXF_HOME` at the plugins shipped with it and layers
[../deploy/offline.config](../deploy/offline.config) automatically.

## Troubleshooting

| What you see | Why |
|---|---|
| `unable to find kraken2 in $KRAKEN2_DB_PATH` | A `KRAKEN2_DB_PATH` inherited from your shell profile. phamseek unsets it and passes an absolute path, so seeing this means kraken2 was invoked outside the pipeline. |
| `kraken2 database ... is incomplete` | `hash.k2d`, `opts.k2d` or `taxo.k2d` is missing from the directory. |
| `No host reference (*.mmi or FASTA) found` | Build the index, or pass `--skip_host_removal` and accept the consequences stated above. |
| `--bracken_read_length is required when bracken is enabled` | bracken was switched on (`--skip_bracken false`) without a read length. Supply the median read length nanoq reports, or leave bracken off. |
| `--skip_bracken must be true or false` | A boolean was given something other than `true`/`false`. Command-line values arrive as strings, and Groovy reads any non-empty string as true, so the pipeline converts them explicitly rather than let `--skip_host_removal false` silently skip host depletion. |
| `Process requirement exceeds available memory` | A task asked for more RAM than the machine has. Lower `--max_memory` (it is a ceiling, not a request). |
| `expected 8 fields from the report join` | A Nextflow version change altered `join(remainder: true)` padding semantics. The pipeline stops rather than assemble a report from possibly mismatched files. |
| `expected reports for N sample(s) but found M` | A sample was dropped between classification and reporting; the summary step refuses to emit a partial run. |
| `read order mismatch at record N` | kraken2 no longer preserved input order, which makes the streaming host split unsafe. The pipeline stops. |
