# Sentieon DNAscope on Carolina Cloud

Germline variant calling: paired FASTQ in, VCF out. Runs on Carolina Cloud —
nothing heavy runs on your own machine.

```
FASTQ pair ──▶ align ──▶ QC metrics ──▶ dedup ──▶ DNAscope ──▶ DNAModelApply ──▶ VCF
```

## 🤖 Quick start with an AI agent

Using Claude Code, or any coding agent? Paste this and it will take it from here:

```text
Please clone https://github.com/Ddfulton/nf-ccloud-sentieon-quickstart and help me get started.
Also read https://console.carolinacloud.io/static/nextflow/local-quickstart.md for more context on nf-ccloud
```

The repo contains a `CLAUDE.md` that walks the agent through setup, tells it
what to ask you for, and makes it run the preflight check before anything
expensive. Everything below is the same process done by hand.

---

## What you need

| | |
|---|---|
| `nextflow` on your PATH | Already installed on a Carolina Cloud head container. Otherwise `curl -s https://get.nextflow.io \| bash` (needs Java 17+). |
| A writable bucket | Scratch and results go here. Budget several hundred GB for WGS. |
| A reference genome **with its BWA index** | See [Preparing the reference](#preparing-the-reference). This is the only part that takes real work. |
| Your FASTQs in object storage | Readable `s3://` URIs. |

Sentieon itself, the DNAscope model, and the license all ship inside the
container image. There is nothing to install and no license to obtain.

## Setup

**1. Edit two lines** in `nextflow.config`:

```groovy
params.bucket = 's3://CHANGE-ME'                        // must be WRITABLE
params.fasta  = 's3://CHANGE-ME/ref/your-reference.fna'  // your genome
```

**2. Edit `samplesheet.csv`**, one row per sample:

```csv
sample,group,fastq_1,fastq_2
SAMPLE1,RG1,s3://your-bucket/fastq/SAMPLE1_R1.fastq.gz,s3://your-bucket/fastq/SAMPLE1_R2.fastq.gz
```

`sample` must be unique per row — it names every output file. `group` is the
read-group ID and defaults to `sample`.

## Run

```bash
nextflow run smoke.nf -c nextflow.config    # preflight, under a minute
nextflow run main.nf  -c nextflow.config    # the real thing
```

Run the preflight first. It checks your credentials, the executor, your
reference index, and the container in well under a minute — catching problems
that would otherwise surface hours into a real run. Add `-resume` to any re-run
to reuse completed work.

Results land in `<your-bucket>/results/<sample>/`:

```
<sample>.vcf.gz          the variant calls
<sample>.vcf.gz.tbi
metrics/                 QC text files and PDF plots
```

Check the PDFs and `aln_metrics.txt` before trusting the VCF.

## Preparing the reference

**A FASTA on its own is not enough.** This pipeline does not build the index for
you. All seven files must sit in the same bucket prefix:

```
your-reference.fna         your-reference.fna.pac
your-reference.fna.amb     your-reference.fna.sa
your-reference.fna.ann     your-reference.fna.fai
your-reference.fna.bwt
```

Build the index once, on a Linux box with ~8 GB RAM. `bwa index` is
single-threaded and takes a couple of hours for a mammalian genome:

```bash
bwa index your-reference.fna
samtools faidx your-reference.fna
```

No local toolchain? Use a container:

```bash
docker run --rm -v "$PWD":/data -w /data biocontainers/bwa:v0.7.17_cv1 \
    bwa index your-reference.fna
```

Then upload the whole set:

```bash
aws s3 cp . s3://your-bucket/ref/ --recursive \
    --exclude "*" --include "your-reference.fna*"
```

> Keep that prefix clean. Every object sharing the FASTA stem is staged into
> each task, so a stray `.fna.gz` costs a pointless multi-GB transfer per task.

## Troubleshooting

| Message | Fix |
|---|---|
| `Cannot create work-dir 's3://CHANGE-ME/…'` | Set `params.bucket`. |
| `Reference is missing BWA index files` | Build the index — see above. |
| `Duplicate sample id(s)` | Make each `sample` value unique. |
| `NoSuchFileException: s3://…` | Wrong path, or your credentials can't see that bucket. |
| Anything about a Sentieon license | Shouldn't happen — it ships in the image. Contact us. |

Full log is `.nextflow.log`; send that rather than a screenshot.

## Files

| | |
|---|---|
| `nextflow.config` | **The only file you edit.** Inputs at the top. |
| `samplesheet.csv` | Your samples. |
| `main.nf` | The pipeline. Don't edit. |
| `smoke.nf` | Preflight check. Don't edit. |
| `CLAUDE.md` | Instructions for an AI agent. |
