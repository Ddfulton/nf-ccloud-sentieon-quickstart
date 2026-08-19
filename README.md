# Horse WGS — Sentieon DNAscope germline variant calling

FASTQ in, VCF out, running on Carolina Cloud. Nothing heavier than Java runs on
your own machine.

```
FASTQ pair ──▶ align ──▶ QC metrics ──▶ dedup ──▶ DNAscope ──▶ DNAModelApply ──▶ VCF
```

A 30× whole genome takes a few hours, most of it in alignment.

---

## Setup

**You edit two lines and one CSV.** Everything else is already configured.

Requires `nextflow` on your PATH. A Carolina Cloud head container already has
it; otherwise `curl -s https://get.nextflow.io | bash` and put it on your PATH
(needs Java 17+).

### With an AI agent

This repo contains a `CLAUDE.md` with step-by-step instructions. Clone it, open
it with Claude Code (or any agent that reads `CLAUDE.md`), and say *"set this up
and run it."* It will ask you for your bucket, check your reference, and run the
preflight test before starting anything expensive.

### By hand

**1. Credentials.** On a Carolina Cloud head container these are already set —
skip this. Otherwise export `CCLOUD_API_KEY`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, and for S3-compatible storage (e.g. Cloudflare R2)
`AWS_REGION` and `AWS_ENDPOINT_URL`.

**2. Your bucket and reference.** Two lines, at the top of `nextflow.config`:

```groovy
params.bucket = 's3://CHANGE-ME'                       // ← must be WRITABLE
params.fasta  = 's3://CHANGE-ME/ref/your-reference.fna' // ← your genome
```

Any reference works. The default names the thoroughbred T2T assembly
(`GCF_041296265.1`) simply because that is what this was tested against —
replace it with yours, wherever it lives.

**3. Your samples.** Edit `samplesheet.csv`:

```csv
sample,group,fastq_1,fastq_2
Horse1,SRR6474875,s3://your-bucket/sample/SRR6474875_1.fastq.gz,s3://your-bucket/sample/SRR6474875_2.fastq.gz
```

`sample` must be unique per row — it names every output file. `group` is the
read-group ID and defaults to `sample`.

---

## Run

```bash
nextflow run smoke.nf -c nextflow.config    # preflight, under a minute
nextflow run main.nf  -c nextflow.config    # the real thing
```

Run the smoke test first. It confirms your credentials, the executor, and the
container in well under a minute — catching problems that would otherwise
surface hours into a real run.

`-resume` on any re-run reuses completed work instead of starting over.

Results land in `results/<sample>/`:

```
<sample>.vcf.gz          the variant calls
<sample>.vcf.gz.tbi
metrics/                 QC text files and PDF plots
```

Start with the PDFs and `aln_metrics.txt` before trusting the VCF.

---

## Preparing the reference genome

**This is the only part that takes real work, and it is a one-time cost.**

The pipeline needs the FASTA *and* its BWA index in one prefix. NCBI ships only
the bare sequence:

```
GCF_041296265.1_TB-T2T_genomic.fna
GCF_041296265.1_TB-T2T_genomic.fna.{amb,ann,bwt,pac,sa}    BWA index
GCF_041296265.1_TB-T2T_genomic.fna.fai                      samtools index
```

The pipeline checks for these before starting and names anything missing.

**Download** the thoroughbred T2T assembly:

```bash
datasets download genome accession GCF_041296265.1 --include genome
unzip ncbi_dataset.zip
```

**Index it** on a Linux box with ~8 GB RAM and a couple of hours. `bwa index` is
single-threaded and slow; this does not run on Carolina Cloud:

```bash
bwa index GCF_041296265.1_TB-T2T_genomic.fna
samtools faidx GCF_041296265.1_TB-T2T_genomic.fna
```

No local toolchain? Use a container:

```bash
docker run --rm -v "$PWD":/data -w /data biocontainers/bwa:v0.7.17_cv1 \
    bwa index GCF_041296265.1_TB-T2T_genomic.fna
```

**Upload** the whole set to `s3://your-bucket/ref/`:

```bash
aws s3 cp . s3://your-bucket/ref/ --recursive \
    --exclude "*" --include "GCF_041296265.1_TB-T2T_genomic*"
```

> Keep that prefix clean. The pipeline stages every object sharing the FASTA
> stem into each task, so a leftover `.fna.gz` costs a pointless multi-GB
> transfer per task.

Any reference works — the commands above just use the assembly we tested with.
Keep the filename stem consistent across the FASTA and its index files, and
point `params.fasta` at wherever you put it.

---

## Troubleshooting

`CLAUDE.md` has the full table. The common ones:

| Message | Fix |
|---|---|
| `Cannot create work-dir 's3://CHANGE-ME/…'` | Set `params.bucket`. |
| `Reference is missing BWA index files` | Build the index — see above. |
| `Duplicate sample id(s)` | Make each `sample` value unique. |
| `Unable to get file attributes` (DEBUG) | Harmless storage quirk; ignore. |
| Anything about a Sentieon license | Should not happen — it ships in the image. Contact us. |

The full log is `.nextflow.log`; send it to us rather than a screenshot.

**Long runs:** `nextflow run` must stay alive. Use `tmux` if there is any chance
of disconnection.

---

## What's here

| File | |
|---|---|
| `nextflow.config` | **The only file you edit.** Inputs at the top. |
| `samplesheet.csv` | Your samples. |
| `main.nf` | The pipeline. Don't edit. |
| `smoke.nf` | Preflight check. Don't edit. |
| `CLAUDE.md` | Instructions for an AI agent. |
