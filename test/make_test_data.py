#!/usr/bin/env python3
"""Regenerate the tiny simulated ONT dataset shipped in test/.

The generated FASTQ files are committed, so this only needs re-running when the
test design changes. It is kept here to document where the sequences came from.

This is a DELIBERATELY SIMPLIFIED read simulator, not a validated ONT error
model: fragments are drawn uniformly from the reference, and errors are applied
as independent per-base substitutions, deletions and insertions at a fixed rate.
Real ONT error is homopolymer- and context-dependent and comes in bursts. The
simulated data is adequate for exercising pipeline wiring and for checking that
a near-neighbour phage is detected; it must NOT be used to estimate sensitivity,
specificity, or any performance figure.

Sources (developer machine only — not needed to run the pipeline):
  * phage : p0126-kraken2phage T1_near_dup.fna — UHGV vOTUs with >=95% ANI to
            INPHARED, so the smoke-test database is guaranteed to contain a
            near neighbour.
  * human : T2T-CHM13v2.0, one N-free window of chr1 — exercises both levels of
            host depletion.

Samples produced:
  * plasma_pos — phage + human            (sample_type=sample, expect detection)
  * plasma_neg — human only               (sample_type=sample, expect no call)
  * ntc_blank  — a handful of human reads (sample_type=ntc)

Usage:
    python3 test/make_test_data.py --outdir test
"""

from __future__ import annotations

import argparse
import gzip
import os
import random
from pathlib import Path

PHAGE_FNA = Path(
    "/home/allen/github/rujinlong/p0126-kraken2phage/data/positive/stratified/T1_near_dup.fna"
)
HUMAN_FNA_GZ = Path("/home/allen/data2/db/human_t2t/chm13v2.fna.gz")

MIN_LEN, MAX_LEN = 1000, 4000
SUB_RATE, DEL_RATE, INS_RATE = 0.02, 0.02, 0.01  # ~5% total, ONT-like ordering
SEED = 20260807

COMPLEMENT = str.maketrans("ACGTNacgtn", "TGCANtgcan")


def revcomp(seq: str) -> str:
    return seq.translate(COMPLEMENT)[::-1]


def read_fasta(path: Path):
    opener = gzip.open if path.suffix == ".gz" else open
    name, chunks = None, []
    with opener(path, "rt") as fh:
        for line in fh:
            if line.startswith(">"):
                if name is not None:
                    yield name, "".join(chunks)
                name, chunks = line[1:].strip().split()[0], []
            else:
                chunks.append(line.strip())
    if name is not None:
        yield name, "".join(chunks)


def grab_human_window(path: Path, window: int, skip: int) -> str:
    with gzip.open(path, "rt") as fh:
        assert fh.readline().startswith(">")
        buf: list[str] = []
        total = 0
        for line in fh:
            if line.startswith(">"):
                break
            s = line.strip()
            total += len(s)
            if total < skip:
                continue
            buf.append(s)
            if sum(len(x) for x in buf) >= window * 3:
                break
        seq = "".join(buf).upper()
    for start in range(0, max(1, len(seq) - window), 10_000):
        cand = seq[start : start + window]
        if len(cand) == window and "N" not in cand:
            return cand
    raise RuntimeError("no N-free human window found; increase --human-skip")


def add_ont_errors(rng: random.Random, seq: str) -> str:
    out = []
    for base in seq:
        r = rng.random()
        if r < DEL_RATE:
            continue
        if r < DEL_RATE + SUB_RATE:
            out.append(rng.choice([b for b in "ACGT" if b != base]))
        else:
            out.append(base)
        if rng.random() < INS_RATE:
            out.append(rng.choice("ACGT"))
    return "".join(out)


def simulate(rng: random.Random, refs, n_reads: int, tag: str):
    total_len = sum(len(s) for _, s in refs)
    out = []
    for i in range(n_reads):
        pick = rng.uniform(0, total_len)
        acc = 0.0
        ref_name, ref_seq = refs[-1]
        for name, seq in refs:
            acc += len(seq)
            if pick <= acc:
                ref_name, ref_seq = name, seq
                break

        length = rng.randint(MIN_LEN, MAX_LEN)
        if length >= len(ref_seq):
            length = len(ref_seq) - 1
        start = rng.randrange(0, max(1, len(ref_seq) - length))
        frag = ref_seq[start : start + length]
        if rng.random() < 0.5:
            frag = revcomp(frag)
        read = add_ont_errors(rng, frag)
        if len(read) < 200:
            continue
        # Per-read mean quality around Q12-Q18, which is typical for ONT and
        # comfortably above the chopper default used by the test profile.
        qchar = chr(33 + rng.randint(12, 18))
        out.append((f"{tag}_{i:06d}_{ref_name}", read, qchar * len(read)))
    return out


def write_reads(records, out_path: Path):
    with gzip.open(out_path, "wt", compresslevel=6) as fh:
        for name, seq, qual in records:
            fh.write(f"@{name}\n{seq}\n+\n{qual}\n")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--outdir", default="test", type=Path)
    ap.add_argument("--phage-fna", default=PHAGE_FNA, type=Path)
    ap.add_argument("--human-fna", default=HUMAN_FNA_GZ, type=Path)
    ap.add_argument("--n-phage", type=int, default=2)
    ap.add_argument("--phage-reads", type=int, default=700)
    ap.add_argument("--human-reads-pos", type=int, default=250)
    ap.add_argument("--human-reads-neg", type=int, default=400)
    ap.add_argument("--human-reads-ntc", type=int, default=120)
    ap.add_argument("--human-window", type=int, default=200_000)
    ap.add_argument("--human-skip", type=int, default=20_000_000)
    args = ap.parse_args()

    rng = random.Random(SEED)
    reads_dir = args.outdir / "reads"
    reads_dir.mkdir(parents=True, exist_ok=True)

    phage_refs = []
    for name, seq in read_fasta(args.phage_fna):
        if 18_000 <= len(seq) <= 50_000:
            phage_refs.append((name, seq.upper()))
        if len(phage_refs) >= args.n_phage:
            break
    if len(phage_refs) < args.n_phage:
        raise SystemExit(f"only found {len(phage_refs)} suitable phage genomes")
    print("phage references:", [(n, len(s)) for n, s in phage_refs])

    human_refs = [
        ("chm13v2_chr1_window", grab_human_window(args.human_fna, args.human_window, args.human_skip))
    ]
    print("human window:", len(human_refs[0][1]), "bp")

    pos = simulate(rng, phage_refs, args.phage_reads, "phage")
    pos += simulate(rng, human_refs, args.human_reads_pos, "human")
    rng.shuffle(pos)
    write_reads(pos, reads_dir / "plasma_pos.fastq.gz")
    print(f"plasma_pos: {len(pos)} reads")

    neg = simulate(rng, human_refs, args.human_reads_neg, "human")
    write_reads(neg, reads_dir / "plasma_neg.fastq.gz")
    print(f"plasma_neg: {len(neg)} reads")

    ntc = simulate(rng, human_refs, args.human_reads_ntc, "human")
    write_reads(ntc, reads_dir / "ntc_blank.fastq.gz")
    print(f"ntc_blank: {len(ntc)} reads")

    sheet = args.outdir / "samplesheet.csv"
    with open(sheet, "w") as fh:
        fh.write("sample_id,fastq,platform,sample_type\n")
        for s, stype in (("plasma_pos", "sample"), ("plasma_neg", "sample"), ("ntc_blank", "ntc")):
            fh.write(f"{s},reads/{s}.fastq.gz,ont,{stype}\n")
    print("wrote", sheet)

    total = sum(
        os.path.getsize(reads_dir / f"{s}.fastq.gz")
        for s in ("plasma_pos", "plasma_neg", "ntc_blank")
    )
    print(f"total FASTQ size: {total/1e6:.2f} MB")


if __name__ == "__main__":
    main()
