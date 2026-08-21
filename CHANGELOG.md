# Changelog

## v0.2.1

Housekeeping. No result changes, and the container image is the one v0.2.0
published — the two tags resolve to the same digest.

- **A release that does not change the image no longer rebuilds it.** The image is a
  function of exactly two files, `pixi.lock` and `docker/Dockerfile`. A `probe` job now
  compares those against the previous `v*` tag; when they are unchanged it points the new
  tag at the existing image with `docker buildx imagetools create` — a registry-side
  operation taking about 20 seconds, after which both tags resolve to the identical digest.
  A manual `workflow_dispatch` always rebuilds.
  - This is not only about the eleven minutes. Two independent builds of the same commit
    and the same lock produced different digests — layers 0–4 and 7 identical, the 2.03 GB
    conda layer differing by 20 KB from `.pyc` files, mtimes and `conda-meta` ordering. A
    rebuild therefore obliges you to argue that the contents are equivalent; a retag leaves
    the new tag on the very same digest, which needs no argument. The job asserts that
    equality before finishing.
- **`summary/versions.yml` is no longer written.** `DB_MANIFEST` and `PHAMSEEK_SUMMARY` both
  publish into `summary/` and both emit a `versions.yml`, so without a `publishDir` pattern
  each wrote one there and whichever task finished later overwrote the other — leaving a
  run-level filename that in fact held one process's versions. Both declarations now name
  the files they publish. The complete, collated list is where it always was, in
  `pipeline_info/software_versions.yml`. No result changes, and the container image is
  untouched.

## v0.2.0

Interactive charts, a `--help` that works, and one renamed parameter.

**Breaking**

- **`--skip_bracken` is now `--run_bracken`, with the polarity reversed.** Enabling
  bracken used to mean typing `--skip_bracken false`, a double negative that could not be
  given as a bare flag. It is now `--run_bracken`, off by default. The old name is
  **refused with an explanation** rather than ignored: an ignored flag would leave bracken
  switched off while the user believed they had switched it on.
- **Nextflow `>=25.10.0` is now required**, up from `>=24.04.0`. The nf-schema plugin
  declares `Plugin-Requires: >=25.10.0`, and Nextflow below that refuses to load it with a
  message about the plugin rather than about the pipeline.

**Added**

- **Krona charts**, one per sample and one for the whole run, in `<sample>/krona/` and
  `summary/phamseek_krona.html`. They are self-contained: Krona inlines its JavaScript and
  embeds its logo, so they open with no network access. Turn them off with `--skip_krona`.
  - The charts cover the **non-host** subtree. Around 82% of classified reads in plasma and
    CSF are *Homo sapiens*, and charting that compresses everything else into an unreadable
    sliver. It also puts the chart on the same denominator as `--min_rpm`.
  - `kreport2krona.py` runs with `--intermediate-ranks`, which its own default turns off.
    Without it, reads that stopped at `root` and reads classified as `plasmids` are
    silently discarded — 74 of 330 non-host reads in the test sample, and precisely the two
    confounders this pipeline reports on. The step now fails if the charted total and the
    non-host read count disagree.
- **`summary/pavian/`**, holding every kraken2 report in one directory, named by sample, so
  [Pavian](https://github.com/fbreitwieser/pavian) can be pointed at it in one go. Pavian
  itself is not in the container and is not run by the pipeline; a `README.txt` in that
  directory says how to launch it and why its bracken panels are empty by default.
- **`--help` works again** — on both Nextflow generations, and without
  `NXF_SYNTAX_PARSER=v1`. `--help <parameter>` prints one parameter in full, and
  `--show_hidden` includes the parameters marked hidden.

**Changed**

- **nf-validation 1.1.3 → nf-schema 2.6.0.** nf-validation is unmaintained; nf-schema is
  its supported successor.
- **The schema now declares the string form of every numeric and boolean parameter.**
  Nextflow 26.04 hands every command-line value to the pipeline as a String, where 25.10
  and earlier converted it to its natural type. nf-validation compensated with
  `validationLenientMode`, which converted the string before validating; nf-schema's
  `validation.lenientMode` is a different thing entirely — it lets a parameter declared as
  *string* accept other scalars — so with it on, `--min_reads 5` was rejected outright.
  Declaring `"type": ["integer", "string"]` with a matching `pattern` works under both
  Nextflow generations and needs no lenient mode. `--kraken2_confidence` is range-checked
  in the pipeline, because JSON Schema's `minimum`/`maximum` do not apply to a string.
- **Help is rendered by the pipeline**, from the same `nextflow_schema.json` the plugin
  validates against. No schema plugin can render it under the strict parser: a bare
  `--help` arrives as the String `"true"`, and every nf-schema release reads a string there
  as "show help for the parameter with this name", so it prints nothing and the pipeline
  runs.
- Messages that named a release ("not implemented in v0.1") now describe the behaviour
  instead, or read the version from the manifest.

**Note for whoever tags this**: the container image is built from the git tag, so
`-profile apptainer` will look for `jinlongru/nf-phamseek:v0.2.0` and find nothing until
`v0.2.0` is pushed and `.github/workflows/docker.yml` has finished. `-profile pixi` and
`-profile nocontainer` work in the meantime.

## v0.1.0

First usable release. Read-level (Tier 1) analysis of Oxford Nanopore reads from
low-biomass clinical samples.

- Standard Nextflow entry point: `nextflow run rujinlong/nf-phamseek`.
- Four software sources, selected with `-profile`: `apptainer` (the default), `docker`,
  `pixi`, `nocontainer`.
- Dependencies pinned by pixi (`pixi.lock`, covering linux-64 and linux-aarch64). The
  container image `jinlongru/nf-phamseek` is built natively for amd64 and arm64 by GitHub
  Actions from that same lock and pushed to Docker Hub, so the container, the pixi route
  and the offline bundle all resolve to one solved environment.
- Samplesheet validation: uniqueness, readability, non-emptiness, the gzip magic number for
  `.gz` files, and vocabularies for platform and sample type. Relative FASTQ paths resolve
  against the samplesheet's own directory.
- QC with chopper and nanoq, measured on both sides of the filter.
- One kraken2 pass over every read at `--confidence 0.02`.
- Two-level host depletion: delete the kraken2 subtree, then align the remainder against
  CHM13v2 with minimap2. Each level reports its own removal count.
- bracken optional and off by default — its model assumes a fixed read length, which ONT
  violates by construction. Even when enabled it is skipped, with a warning, if the
  database carries no k-mer distributions.
- Per-sample TSV and JSON, plus one self-contained run-level HTML report that depends on no
  external resource.
- Chimera diagnostics, labelled explicitly as a non-specific auxiliary signal.
- A database manifest pinning which database produced each set of results.
- `--mode full` (the assembly tier) fails with an explanation rather than running a partial
  path.
