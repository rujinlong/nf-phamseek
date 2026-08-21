# Building and shipping phamseek

This document is for us, not for the collaborator. What they receive is
[INSTALL.md](INSTALL.md) — the English one they follow step by step.

---

## What is here

| File | Runs on | Purpose |
|---|---|---|
| [preflight.sh](preflight.sh) | target machine | Read-only health check; prints a report, writes `preflight.json`, exits 0/1/2 (3 for a bad argument) |
| [pack_offline.sh](pack_offline.sh) | our machine, online | Builds the route B offline bundle |
| [apptainer/phamseek.def](apptainer/phamseek.def) | our machine | Container definition; consumes the route B payload directly |
| [apptainer/build_sif.sh](apptainer/build_sif.sh) | our machine | Prepares the inputs and runs `apptainer build` |
| [db_package.sh](db_package.sh) | our machine | Splits a database into volumes, checksums it, records a functional fingerprint |
| [db_verify.sh](db_verify.sh) | target machine | Four verification gates; ships alongside every database package |
| [offline.config](offline.config) | target machine | Nextflow hardening, layered on with `-c` |
| [assets/smoke_contigs.fna](assets/smoke_contigs.fna) | both | The fixed 12-sequence input gate 4 runs against |

---

## The one rule that cannot be broken

`pixi.lock` is the single source of truth for which software ships. All three routes derive
from it and from nothing else:

- Route A resolves it directly with `pixi install --frozen`.
- Route B packs exactly those locked packages with `pixi-pack`.
- Route C **consumes route B's payload verbatim**. The container never solves an environment
  of its own — a container that re-solves makes the lock file decorative.

The moment you find yourself running `pixi install` without `--frozen`, or adding a
`conda install` to Apptainer's `%post`, stop: the three routes have quietly diverged.

---

## Architecture strategy

Development and verification happen on linux-aarch64 (DGX Spark). The collaborator's
workstation is linux-64. `pixi.lock` carries both platforms, so both resolve.

**We do not cross-build.** No qemu, no cross-architecture CI. `pixi-pack
--create-executable` embeds a `pixi-unpack` binary that has to match the target platform,
and Apptainer only builds natively. Each architecture is built on a machine of that
architecture. [build_sif.sh](apptainer/build_sif.sh) refuses a mismatched `--platform`
outright rather than producing a broken image.

---

## Deployment day: building the linux-64 artefacts

Run these on **any networked x86_64 Linux machine**. This exact sequence has not been
executed yet — the aarch64 one has, and the only difference is the platform argument.

```bash
# --- 0. Tools (once per machine) --------------------------------------------
curl -fsSL https://pixi.sh/install.sh | bash
export PATH="$HOME/.pixi/bin:$PATH"
pixi global install pixi-pack

# --- 1. Get the repository --------------------------------------------------
git clone https://github.com/rujinlong/nf-phamseek.git
cd nf-phamseek

# --- 2. Materialise the environment from the lock, never re-solving ---------
#     Required: pack_offline.sh uses this nextflow to pre-fetch the plugins.
pixi install --frozen

# --- 3. Route B: the offline bundle -----------------------------------------
./deploy/pack_offline.sh --platform linux-64
#     -> dist/phamseek-offline-v0.2.0-linux-64/
#     -> dist/phamseek-offline-v0.2.0-linux-64.tar.zst        (~1.2 GB)
#        falls back to .tar.gz on a machine without zstd
#     -> dist/phamseek-offline-v0.2.0-linux-64.tar.zst.sha256

# --- 4. Route C: the container ----------------------------------------------
./deploy/apptainer/build_sif.sh --platform linux-64
#     -> ~/singularity/phamseek-0.2.0-x86_64.img              (~1.5 GB)
#     -> ~/singularity/phamseek-0.2.0-x86_64.img.sha256

# --- 5. Prove the bundle installs with no network ---------------------------
#     Redo the air-gap test on x86_64 before shipping. Do not skip it:
#     it is what caught the missing CA store on aarch64.
apptainer build /tmp/deb12.sif docker://debian:12-slim
cp -a dist/phamseek-offline-v0.2.0-linux-64 /tmp/ag/bundle
apptainer exec --net --network=none --cleanenv \
  -B /tmp/ag:/tmp/ag \
  -B /etc/ssl/certs:/etc/ssl/certs:ro \
  /tmp/deb12.sif \
  bash -c 'export HOME=/tmp/ag/home; mkdir -p $HOME
           bash /tmp/ag/bundle/install.sh /tmp/ag/phamseek
           source /tmp/ag/phamseek/activate.sh
           nextflow -version && kraken2 --version'

# --- 6. Verify the container ------------------------------------------------
apptainer exec --cleanenv ~/singularity/phamseek-0.2.0-x86_64.img kraken2 --version
apptainer exec --cleanenv \
  -B /path/to/databases:/db:ro \
  ~/singularity/phamseek-0.2.0-x86_64.img \
  kraken2 --db /db/inphared_7Apr2026 --confidence 0.02 \
          --output /dev/null --report /dev/stdout \
          /opt/phamseek/pipeline/deploy/assets/smoke_contigs.fna
```

`--net --network=none` is a real air gap: loopback only, DNS resolution fails, and no root
required. Unprivileged `unshare -rn` **does not work** on our machines — AppArmor's
`kernel.apparmor_restrict_unprivileged_userns=1` blocks it.

---

## Packaging a database

```bash
# The small database, for smoke-testing the pipeline itself
./deploy/db_package.sh \
    --db-dir /home/allen/data2/db/kraken2/inphared_7Apr2026 \
    --name inphared_7Apr2026 \
    --out /mnt/nas26/outbox --volume-size 2G \
    --source "INPHARED 7 Apr 2026 cultured phage genomes + ICTV taxonomy"

# The production database
./deploy/db_package.sh \
    --db-dir /home/allen/data2/db/kraken2/inphared_decoy \
    --name inphared_decoy \
    --out /mnt/nas26/outbox --volume-size 2G --threads 16 \
    --source "INPHARED 7 Apr 2026 + bacteria/plasmid/human decoy"
#   level chosen automatically: 7.7 GiB -> zstd -3
```

A few things that matter:

- **`--level` is now chosen from the database size**; do not set it by hand under normal
  circumstances: 3 above 2 GiB, 19 otherwise. A kraken2 hash table is close to
  incompressible, so level 19 on a 7.7 GB database burns roughly an extra hour of CPU and
  saves almost nothing. The chosen level and the reason for it are printed at the start of
  every run.
- **Always `--sign` when the recipient is an institution.** A checksum proves integrity;
  only a signature proves who it came from, and the latter is what a hospital's information
  security office asks for. The public key travels by a separate channel. **Not yet enabled
  — see Known gaps.**
- **`--no-host-metadata`** strips our hostname and the absolute source path out of the
  manifest, for recipients who treat internal paths as disclosure.
- **Package a frozen build, never a directory still being written.** The manifest and the
  tar are two independent passes over the same data; if the database can change between
  them, the package contradicts itself and gate 3 fails inexplicably on the receiving side.
- **`--long=31` on both the compressing and the decompressing side.** Without it on
  decompression, zstd **refuses** the large-window frame with "Frame requires too much
  memory for decoding" — a decoder limit that reads exactly like data corruption.

Always walk the receiving side yourself before shipping:

```bash
./deploy/db_verify.sh --package-dir /mnt/nas26/outbox/inphared_decoy_YYYYMMDD \
                      --dest /tmp/verify-scratch
```

---

## The database layout expected on the target machine

`--db_dir` is a root directory with one subdirectory per database. **This layout is fixed:**

```
<db_dir>/
├── kraken2/<db_name>/   hash.k2d, opts.k2d, taxo.k2d   required (inphared_decoy recommended)
├── host/                minimap2 CHM13v2 .mmi index    required
├── genomad_db/          for the assembly tier — absence is normal
└── checkv/              for the assembly tier — absence is normal
```

[preflight.sh](preflight.sh) recognises three shapes: the root above, a flat
`<db_dir>/kraken2/`, and a path pointing straight at one kraken2 database. It reports which
one it found. It searches with `find -L` so that a database directory which is a symlink to
another volume is still traversed — ours are stored that way, and without `-L` find silently
returns nothing.

The pipeline descends the same way, in `descendIntoSingleDatabase()`
([utils_phamseek_pipeline/main.nf](../subworkflows/local/utils_phamseek_pipeline/main.nf)).
**Keep the two in step.** When they disagree the failure is the worst kind: preflight passes
and the pipeline then reports `hash.k2d is missing`, so the check that existed to catch the
problem is what gave the false confidence. The pipeline descends only when the choice is
unambiguous — several databases side by side is a real setup, and silently picking one would
be worse than asking.

The severity levels are deliberate: **a missing `host/` is a WARN** (host depletion is on by
default, but `--skip_host_removal true` is a genuine fallback), while **missing
`genomad_db/` and `checkv/` are INFO** — only the read-level tier is implemented, their
absence is the expected state, and a warning would send the collaborator hunting for
databases nothing uses yet.

---

## Measured defaults hardcoded in the scripts

Two numbers in the deployment layer come from measurement rather than convention. Changing
either means changing every location listed here together.

| Value | Where it appears | Basis |
|---|---|---|
| `--confidence 0.02` | gate 4 of [db_package.sh](db_package.sh) and [db_verify.sh](db_verify.sh); explained in [INSTALL.md](INSTALL.md) | The 0.10 that short-read work uses costs sensitivity on ONT: 15 points at 95% read identity, 29 points at 87%. kraken2's own default of 0 calls a taxon on a single k-mer hit. ONT pilot data: [p0126-kraken2phage/results/ont_pilot/](file:///home/allen/github/rujinlong/p0126-kraken2phage/results/ont_pilot/) |
| `PHAMSEEK_PROD_DB_GB=8` | [preflight.sh](preflight.sh), used only when `--db-dir` is not given | `uhgv_heldout_decoy` (11 GB on disk) peaked at 10.8 GB RSS, so resident memory tracks database size roughly 1:1. 7.7 GB plus headroom, rounded to 8. With `--db-dir` given, preflight measures the real database instead. |

Gate 4 compares taxids exactly, so the confidence value is baked into every
`SMOKE_EXPECTED.tsv` already written. Changing it invalidates every database package already
shipped — they will fail gate 4 on re-verification. Change it and you repackage.

## Adding a Nextflow plugin

[pack_offline.sh](pack_offline.sh) discovers plugins by grepping
[nextflow.config](../nextflow.config) for `id 'name@version'`, and pre-fetches each into the
bundle's `NXF_HOME`. Two rules:

- **Pin the version.** An unversioned `id 'nf-schema'` does not match that grep, is not
  pre-fetched, and ends as a failed download on the target machine.
- **Re-run [pack_offline.sh](pack_offline.sh) after changing the plugin list.** A bundle
  carries the plugins that existed when it was built.

The framework jar itself needs no pre-fetching: bioconda's `nextflow` package ships
`nextflow-<ver>-one.jar` under `$PREFIX/share/nextflow/dist`, and the launcher does not go
looking for it. Verified with a clean `NXF_HOME` — no `framework/` or `capsule/` directory
is created.

---

## Known gaps

Recorded rather than fixed, so the next person does not rediscover them.

- **Database packages are not signed yet.** `--sign <key-id>` is implemented and produces
  detached armored signatures over `MANIFEST.tsv` and `SHA256SUMS.volumes` plus an exported
  public key, but no key has been chosen. A signature asserts authorship, so which key and
  under whose identity is the user's decision. **A key must be chosen before the first
  formal release** — hospital information security asks for authenticity, and a checksum
  only offers integrity. Until then [db_package.sh](db_package.sh) prints a warning on every
  run.
- **preflight has no end-to-end pipeline smoke test.** It verifies the machine, not the
  installation. A `--deep` mode — network forced off, the delivered pipeline run once on a
  tiny fixture — would turn "this machine looks fine" into "this installation has actually
  run here". It is the highest-value improvement left.
- **The geNomad and CheckV databases are checked for existence only.** Tool/database version
  compatibility is not verified. The right fix is to copy the kraken2 approach: record each
  tool's output on a fixed fixture at packaging time, and re-check it on receipt.
- **The packed environment contains one broken symlink** (`tensorflow/libtensorflow.so.2`).
  It is identical in an environment produced by a plain `pixi install`, so it comes from the
  upstream conda package rather than from packaging. geNomad, which depends on tensorflow,
  runs fine. Do not add a "no dangling symlinks" check: it would fail a working installation.
