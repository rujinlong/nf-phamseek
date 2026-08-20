#!/usr/bin/env python3
"""Regenerate the simulated ONT dataset shipped in test/.

The FASTQ files are committed, so this only needs re-running when the test
design changes. It is kept here to document where the reads came from.

Simulator
---------
Reads are produced by **Badread** (Wick RR, JOSS 2019), not by a hand-written
error model. Badread reproduces the parts of real nanopore data this pipeline
actually reacts to: a realistic fragment-length distribution, a context- and
homopolymer-dependent error model, per-base qscores drawn from a matching
model, adapters, glitches, junk/random reads, and -- the one that matters most
here -- CHIMERIC reads, which is the artefact the collaborator's short-cDNA
ligation libraries are dominated by and which phamseek reports on.

The parameters below describe a short-cDNA nanopore library from a low-biomass
clinical sample, not a genomic run:

  * --length 1500,800     short cDNA fragments, not 15 kb genomic reads
  * --chimeras 5          5% of reads are two fragments joined
  * --identity 92,99,4    ~92% mean read identity (the regime where the
                          --kraken2_confidence default matters most)

This is still simulated data. It exercises wiring, host depletion in both
directions, the chimera diagnostics and detection of a near-neighbour phage.
It must NOT be used to estimate sensitivity, specificity or any performance
figure -- those come from the p0126-kraken2phage benchmark.

Sources (developer machine only -- not needed to run the pipeline):
  * phage : p0126-kraken2phage T1_near_dup.fna -- UHGV vOTUs with >=95% ANI to
            INPHARED, so an INPHARED-derived database is guaranteed to contain
            a near neighbour. Three genomes are used, not all 1000.
  * human : T2T-CHM13v2.0, one N-free window of chr1 -- exercises both levels
            of host depletion.

Samples produced (human-dominated, as clinical plasma is):
  * plasma_pos -- ~13% phage reads over human background (expect detection)
  * plasma_neg -- human only                            (expect no call)
  * ntc_blank  -- a handful of human reads              (sample_type=ntc)

Requires badread on PATH:  pixi global install badread

Usage:
    python3 test/make_test_data.py --outdir test
"""

from __future__ import annotations

import argparse
import gzip
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PHAGE_FNA = Path(
    "/home/allen/github/rujinlong/p0126-kraken2phage/data/positive/stratified/T1_near_dup.fna"
)
HUMAN_FNA_GZ = Path("/home/allen/data2/db/human_t2t/chm13v2.fna.gz")

N_PHAGE_GENOMES = 3
HUMAN_WINDOW = 2_000_000
HUMAN_SKIP = 20_000_000          # past chr1's leading telomere/satellite

# Badread settings shared by every sample. See the module docstring for why
# these differ from Badread's genomic defaults.
BADREAD_COMMON = [
    "--length", "1500,800",
    "--identity", "92,99,4",
    "--error_model", "nanopore2023",
    "--qscore_model", "nanopore2023",
    "--chimeras", "5",
    "--junk_reads", "1",
    "--random_reads", "1",
]

# sample -> [(reference key, bases to simulate, seed), ...]
DESIGN = {
    "plasma_pos": [("phage", 400_000, 1), ("human", 2_600_000, 2)],
    "plasma_neg": [("human", 3_000_000, 3)],
    "ntc_blank":  [("human", 100_000, 4)],
}


def read_fasta(path: Path):
    name, chunks = None, []
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt") as handle:
        for line in handle:
            if line.startswith(">"):
                if name is not None:
                    yield name, "".join(chunks)
                name, chunks = line[1:].strip(), []
            else:
                chunks.append(line.strip())
    if name is not None:
        yield name, "".join(chunks)


def write_fasta(records, path: Path) -> None:
    with path.open("w") as handle:
        for name, seq in records:
            handle.write(f">{name}\n")
            for i in range(0, len(seq), 60):
                handle.write(seq[i : i + 60] + "\n")


def grab_human_window(path: Path, window: int, skip: int) -> str:
    """One N-free window of the first chromosome."""
    for _, seq in read_fasta(path):
        upper = seq.upper()
        start = skip
        while start + window <= len(upper):
            chunk = upper[start : start + window]
            if "N" not in chunk:
                return chunk
            start += window
        raise SystemExit(f"no N-free {window} bp window found after {skip}")
    raise SystemExit(f"{path} holds no sequence")


def badread(reference: Path, bases: int, seed: int) -> bytes:
    cmd = [
        "badread", "simulate",
        "--reference", str(reference),
        "--quantity", str(bases),
        "--seed", str(seed),
        *BADREAD_COMMON,
    ]
    done = subprocess.run(cmd, capture_output=True)
    if done.returncode != 0:
        sys.stderr.write(done.stderr.decode(errors="replace")[-4000:])
        raise SystemExit(f"badread failed for {reference}")
    return done.stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--outdir", type=Path, default=Path("test"))
    args = parser.parse_args()

    if shutil.which("badread") is None:
        raise SystemExit("badread not found on PATH -- 'pixi global install badread'")
    for src in (PHAGE_FNA, HUMAN_FNA_GZ):
        if not src.exists():
            raise SystemExit(f"missing source reference: {src}")

    reads_dir = args.outdir / "reads"
    reads_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)

        phage = [
            (name, seq)
            for name, seq in list(read_fasta(PHAGE_FNA))[:N_PHAGE_GENOMES]
        ]
        phage_ref = tmpdir / "phage.fna"
        write_fasta(phage, phage_ref)
        print(
            "phage reference: "
            + ", ".join(f"{n} ({len(s)} bp)" for n, s in phage),
            file=sys.stderr,
        )

        human_ref = tmpdir / "human.fna"
        write_fasta(
            [("chm13v2_chr1_window", grab_human_window(HUMAN_FNA_GZ, HUMAN_WINDOW, HUMAN_SKIP))],
            human_ref,
        )

        refs = {"phage": phage_ref, "human": human_ref}

        for sample, parts in DESIGN.items():
            fastq = b"".join(badread(refs[key], bases, seed) for key, bases, seed in parts)
            out = reads_dir / f"{sample}.fastq.gz"
            with gzip.open(out, "wb", compresslevel=9) as handle:
                handle.write(fastq)
            n_reads = fastq.count(b"\n") // 4
            print(f"{out}  {n_reads} reads  {out.stat().st_size / 1e6:.2f} MB", file=sys.stderr)

    samplesheet = args.outdir / "samplesheet.csv"
    samplesheet.write_text(
        "sample_id,fastq,platform,sample_type\n"
        "plasma_pos,reads/plasma_pos.fastq.gz,ont,sample\n"
        "plasma_neg,reads/plasma_neg.fastq.gz,ont,sample\n"
        "ntc_blank,reads/ntc_blank.fastq.gz,ont,ntc\n"
    )
    print(f"{samplesheet}", file=sys.stderr)


if __name__ == "__main__":
    main()
