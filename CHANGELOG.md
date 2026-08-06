# Changelog

## v0.1.0

First working version. Read-level (Tier 1) analysis of Oxford Nanopore reads from
low-biomass clinical samples.

- Single command: `bin/phamseek run`.
- Dependencies pinned by pixi (`pixi.lock`, linux-64 and linux-aarch64), one environment
  activated per task via `pixi shell-hook`.
- Samplesheet validation: uniqueness, readability, gzip integrity, platform and
  sample-type vocabularies; relative FASTQ paths resolve against the samplesheet.
- QC with chopper and nanoq, before and after.
- kraken2 at `--confidence 0.02`, one pass over every read.
- Two-level host depletion: kraken2 subtree deletion, then minimap2 against CHM13v2.
  Both levels report their removal counts.
- Optional bracken; skipped with a warning when the database lacks k-mer distributions.
- Per-sample TSV/JSON and a self-contained run-level HTML report with no external
  resources.
- Chimera diagnostics, explicitly labelled as non-specific auxiliary signals.
- Database manifest pinning the database that produced each result.
- `--mode full` (assembly tier) fails with an explanation rather than running partially.
