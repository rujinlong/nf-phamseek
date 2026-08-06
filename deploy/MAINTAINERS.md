# Building and shipping phamseek

For us, not for the collaborator. Their document is [INSTALL.md](INSTALL.md).

---

## What lives here

| File | Runs where | Purpose |
|---|---|---|
| [preflight.sh](preflight.sh) | target machine | read-only health check; prints a report, writes `preflight.json`, exits 0/1/2 |
| [pack_offline.sh](pack_offline.sh) | our machine, online | builds the route B bundle |
| [apptainer/phamseek.def](apptainer/phamseek.def) | our machine | container definition; consumes the route B payload |
| [apptainer/build_sif.sh](apptainer/build_sif.sh) | our machine | stages the inputs and runs `apptainer build` |
| [db_package.sh](db_package.sh) | our machine | splits, checksums and functionally fingerprints a database |
| [db_verify.sh](db_verify.sh) | target machine | four-gate verification; travels inside every package |
| [offline.config](offline.config) | target machine | Nextflow hardening, layered with `-c` |
| [assets/smoke_contigs.fna](assets/smoke_contigs.fna) | both | the fixed 12-sequence input behind gate 4 |

---

## The one thing that must stay true

`pixi.lock` is the single source of truth for what software ships. All three routes are
derived from it and from nothing else:

- Route A resolves it directly with `pixi install --frozen`.
- Route B packs the exact same locked packages with `pixi-pack`.
- Route C **consumes the route B payload**. The container never solves an environment,
  because a container that re-solves makes the lock file decorative.

If you ever find yourself running `pixi install` without `--frozen`, or adding a
`conda install` to the Apptainer `%post`, stop: the three routes have silently diverged.

---

## Architecture policy

Development and validation happen on linux-aarch64 (DGX Spark). The collaborator's
workstation is linux-64. Both platforms are in `pixi.lock` and both resolve.

**We do not cross-build.** No qemu, no cross-architecture CI. `pixi-pack --create-executable`
embeds a `pixi-unpack` binary that must match the target, and Apptainer builds natively
only. Each architecture is built on its own machine. [build_sif.sh](apptainer/build_sif.sh)
refuses a mismatched `--platform` rather than producing a broken image.

---

## Deployment day: building the linux-64 artifacts

Run these on **any x86_64 Linux machine with internet access**. Nothing here has been
executed yet — the aarch64 equivalents have, and the only difference is the platform
argument.

```bash
# --- 0. Get the tools (once per machine) -----------------------------------
curl -fsSL https://pixi.sh/install.sh | bash
export PATH="$HOME/.pixi/bin:$PATH"
pixi global install pixi-pack

# --- 1. Get the repository --------------------------------------------------
git clone https://github.com/rujinlong/phamseek.git
cd phamseek

# --- 2. Materialize the environment from the lock, never re-solving ---------
#     Needed because pack_offline.sh uses this nextflow to pre-fetch plugins.
pixi install --frozen

# --- 3. Route B: the offline bundle ----------------------------------------
./deploy/pack_offline.sh --platform linux-64
#     -> dist/phamseek-offline-v0.1.0-linux-64/
#     -> dist/phamseek-offline-v0.1.0-linux-64.tar.zst        (~1.2 GB)
#     -> dist/phamseek-offline-v0.1.0-linux-64.tar.zst.sha256

# --- 4. Route C: the container ---------------------------------------------
./deploy/apptainer/build_sif.sh --platform linux-64
#     -> ~/singularity/phamseek-0.1.0-x86_64.img              (~1.5 GB)
#     -> ~/singularity/phamseek-0.1.0-x86_64.img.sha256

# --- 5. Prove the bundle installs with no network --------------------------
#     Repeat the air-gap test on x86_64 before shipping. Do not skip this:
#     it is what caught the missing-CA-store failure on aarch64.
apptainer build /tmp/deb12.sif docker://debian:12-slim
cp -a dist/phamseek-offline-v0.1.0-linux-64 /tmp/ag/bundle
apptainer exec --net --network=none --cleanenv \
  -B /tmp/ag:/tmp/ag \
  -B /etc/ssl/certs:/etc/ssl/certs:ro \
  /tmp/deb12.sif \
  bash -c 'export HOME=/tmp/ag/home; mkdir -p $HOME
           bash /tmp/ag/bundle/install.sh /tmp/ag/phamseek
           source /tmp/ag/phamseek/activate.sh
           nextflow -version && kraken2 --version'

# --- 6. Verify the container ------------------------------------------------
apptainer exec --cleanenv ~/singularity/phamseek-0.1.0-x86_64.img kraken2 --version
apptainer exec --cleanenv \
  -B /path/to/databases:/db:ro \
  ~/singularity/phamseek-0.1.0-x86_64.img \
  kraken2 --db /db/inphared_7Apr2026 --confidence 0.02 \
          --output /dev/null --report /dev/stdout \
          /opt/phamseek/pipeline/deploy/assets/smoke_contigs.fna
```

`--net --network=none` gives a real air gap: loopback only, DNS fails. It needs no root.
Unprivileged `unshare -rn` does **not** work on our machines — AppArmor's
`kernel.apparmor_restrict_unprivileged_userns=1` blocks it.

---

## Packaging a database

```bash
# Small database, for smoke testing the pipeline itself
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
#   level is auto-selected: 7.7 GiB -> zstd -3
```

Notes that matter:

- **`--level` is now chosen from the database size** and you should not normally set it:
  3 above 2 GiB, 19 below. A kraken2 hash table is close to incompressible, so level 19 on
  7.7 GB costs about an hour of CPU and saves almost nothing. The chosen level and the
  reason are printed at the top of every run.
- **`--sign` whenever the recipient is an institution.** Checksums prove integrity;
  only a signature proves authorship, and hospital information security asks for the
  latter. Send the public key by a separate channel. **Not yet enabled — see Known gaps.**
- **`--no-host-metadata`** omits our hostname and absolute source path from the manifest
  if the recipient treats internal paths as information disclosure.
- **Package a sealed build, never a live directory.** The manifest and the tar are
  produced by separate passes over the data; if the database can change between them,
  the package is internally inconsistent and gate 3 will fail on the receiving side for
  no visible reason.
- `--long=31` is used on both the compressing and decompressing side. Without it on the
  decompressing side, zstd **refuses** a large-window frame with "Frame requires too much
  memory for decoding" — a decoder limit that reads exactly like corruption.

Always verify your own package through the receiving path before shipping it:

```bash
./deploy/db_verify.sh --package-dir /mnt/nas26/outbox/inphared_decoy_YYYYMMDD \
                      --dest /tmp/verify-scratch
```

---

## Database layout expected on the target

`--db_dir` is a root directory holding one subdirectory per database. **This layout is
fixed for v0.1:**

```
<db_dir>/
├── kraken2/<db_name>/   hash.k2d, opts.k2d, taxo.k2d   REQUIRED (default inphared_decoy)
├── host/                minimap2 CHM13v2 .mmi index    REQUIRED
├── genomad_db/          reserved for v0.2 — absent is normal
└── checkv/              reserved for v0.2 — absent is normal
```

[preflight.sh](preflight.sh) resolves three shapes: this root, a flat
`<db_dir>/kraken2/`, and a bare kraken2 database directory. It reports which one it found.
`find -L` is used so a database directory that is a symlink to another volume is still
traversed — our own databases are laid out that way, and without `-L` find silently
returns nothing.

Severity is deliberate: **missing `host/` is a WARN** (host depletion is on by default,
but `--skip_host_removal true` is a real fallback), while **missing `genomad_db/` and
`checkv/` are INFO** — v0.1 is Tier 1 only, so their absence is the expected state and a
warning would send the collaborator hunting for databases that do not yet matter.

---

## Measured defaults these scripts hard-code

Two numbers appear in the deploy layer and both come from measurement, not convention.
If either is ever changed, change it in all the places listed.

| Value | Where | Evidence |
|---|---|---|
| `--confidence 0.02` | [db_package.sh](db_package.sh) and [db_verify.sh](db_verify.sh) gate 4; documented in [INSTALL.md](INSTALL.md) | The short-read convention of 0.10 costs 15–29 percentage points of sensitivity on ONT reads. kraken2's own default of 0 calls a taxon on one k-mer hit. ONT pilot data: `p0126-kraken2phage/results/ont_pilot/` |
| `PHAMSEEK_PROD_DB_GB=8` | [preflight.sh](preflight.sh), used only when no `--db-dir` is given | `uhgv_heldout_decoy` (11 GB on disk) measured at 10.8 GB peak RSS, so resident size tracks database size roughly 1:1. 7.7 GB + headroom rounds to 8. With a `--db-dir` the preflight measures the real database instead of using this. |

Gate 4 compares taxids exactly, so the confidence value is baked into every
`SMOKE_EXPECTED.tsv`. Changing it invalidates every database package already shipped —
they would fail gate 4 on re-verification. Repackage if you change it.

## Adding a Nextflow plugin

[pack_offline.sh](pack_offline.sh) discovers plugins by grepping `nextflow.config` for
`id 'name@version'` and pre-fetches each one into the bundle's `NXF_HOME`. Two rules:

- **Always pin a version.** An unpinned `id 'nf-schema'` is not matched by the grep, is
  not pre-fetched, and fails on the target with a download error.
- **Re-run `pack_offline.sh` after changing the plugin list.** The bundle carries the
  plugins that existed when it was built.

The framework jar itself does not need pre-fetching: the bioconda `nextflow` package
ships `nextflow-<ver>-one.jar` under `$PREFIX/share/nextflow/dist`, so the launcher never
downloads it. Verified with a clean `NXF_HOME` — no `framework/` or `capsule/` directory
is created.

---

## Known gaps

Recorded rather than fixed, so the next person does not rediscover them.

- **Database packages are not signed yet.** `--sign <key-id>` is implemented and produces
  detached armored signatures over `MANIFEST.tsv` and `SHA256SUMS.volumes` plus an exported
  public key, but no key has been designated. Signing attributes authorship, so the key and
  the publishing identity are the user's decision. **Choose a key before the first real
  release** — hospital information security asks for authenticity, and checksums only
  provide integrity. Until then `db_package.sh` prints a warning on every run.
- **No end-to-end pipeline smoke run in the preflight.** The preflight validates the
  machine, not the installation. A `--deep` mode that runs the delivered pipeline on a
  tiny fixture with the network forced off would convert "this machine looks plausible"
  into "this exact installation ran here". It is the single highest-value addition left.
- **geNomad and CheckV databases are checked for existence only.** Their tool/database
  version compatibility is not verified. The right fix mirrors the kraken2 approach:
  record each tool's output on a fixed fixture at packaging time and re-check it on
  receipt.
- **One broken symlink in the packed environment**
  (`tensorflow/libtensorflow.so.2`). It is present identically in a plain
  `pixi install` environment, so it comes from the upstream conda package and is not a
  packing artifact. geNomad, which depends on tensorflow, runs correctly. Do not add a
  "no broken symlinks" check: it would reject a working install.
