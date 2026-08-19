# Instructions for Claude

You are helping set up and run a Sentieon DNAscope germline variant-calling
pipeline on Carolina Cloud. Work through the checklist below in order. Do not
skip the smoke test.

## What must not change

`main.nf` and `smoke.nf` are complete and tested. Do not edit them. Every value
a user needs to set lives in the `REQUIRED INPUTS` block at the top of
`nextflow.config`.

## Checklist

### 0. Confirm nextflow is available

```bash
nextflow -version
```

If that fails, the user is not on a Carolina Cloud head container. Install with
`curl -s https://get.nextflow.io | bash` (needs Java 17+) and ensure it is on
PATH before continuing.

### 1. Confirm credentials are present

```bash
echo "${CCLOUD_API_KEY:+CCLOUD_API_KEY ok}"
echo "${AWS_ACCESS_KEY_ID:+AWS_ACCESS_KEY_ID ok}"
```

On a Carolina Cloud Nextflow Head container these are already set — do nothing. If
either is empty, the user is running somewhere else and must export:
`CCLOUD_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and — for
S3-compatible storage such as Cloudflare R2 — `AWS_REGION` and
`AWS_ENDPOINT_URL`. Ask the user for these; never invent them.

### 2. Set the bucket and the reference

Edit **two lines** in the `REQUIRED INPUTS` block of `nextflow.config`:

```groovy
params.bucket = 's3://CHANGE-ME'
params.fasta  = 's3://CHANGE-ME/ref/your-reference.fna'
```

`params.bucket` must be a bucket the user can **write** to — scratch space and
results go there, and a WGS run needs several hundred GB.

`params.fasta` is the full path to their reference. **Do not assume it matches
the default.** That assembly is just what this pipeline was tested against; the
user's reference may have a different name, live in a different prefix, or sit
in a different bucket entirely. Ask them for the actual path.

Verify:
```bash
aws s3 ls s3://their-bucket/ ${AWS_ENDPOINT_URL:+--endpoint-url $AWS_ENDPOINT_URL}
```

### 3. Check the reference genome

The pipeline needs the FASTA **and** its BWA index in the same prefix:

```
your-reference.fna
your-reference.fna.{amb,ann,bwt,pac,sa,fai}
```

```bash
aws s3 ls s3://their-bucket/ref/ ${AWS_ENDPOINT_URL:+--endpoint-url $AWS_ENDPOINT_URL}
```

If only the `.fna` is there, the index must be built first — this is a one-time
job needing ~8 GB RAM and a couple of hours, and it does **not** run on Carolina
Cloud. See README.md step 3. Do not try to work around a missing index; the
pipeline will refuse to start and it is right to.

Filenames are illustrative. Only the layout matters: the FASTA plus its index
files sharing one stem in one prefix.

### 4. Fill in the samplesheet

Edit `samplesheet.csv`. One row per sample:

```csv
sample,group,fastq_1,fastq_2
SAMPLE1,RG1,s3://their-bucket/fastq/SAMPLE1_R1.fastq.gz,s3://their-bucket/fastq/SAMPLE1_R2.fastq.gz
```

- `sample` must be **unique per row** — it names every output file. The pipeline
  aborts on duplicates rather than silently producing wrong results.
- `group` is the read-group ID. Optional; defaults to `sample`.
- FASTQ paths must be `s3://` URIs the user can read.

One animal sequenced across several runs is **not** several rows — merging runs
into one VCF is a change to the pipeline, not the samplesheet. Tell the user to
contact Carolina Cloud if they need that.

### 5. Smoke test — do not skip

```bash
nextflow run smoke.nf -c nextflow.config
```

Expect `ALL CHECKS PASSED`. This takes under a minute and catches credential,
executor, and container problems that would otherwise surface hours into a real
run. If it fails, fix it before going further and do not proceed.

### 6. Run

```bash
nextflow run main.nf -c nextflow.config
```

Hours for a WGS sample, mostly in alignment. The `nextflow` process must stay
alive — use `tmux` if there is any chance of disconnection. Add `-resume` to
any re-run to reuse completed work.

Results land in `<your-bucket>/results/<sample>/`:
- `<sample>.vcf.gz` — the variant calls
- `metrics/` — QC text files and PDF plots

## If something fails

| Message | Meaning |
|---|---|
| `Cannot create work-dir 's3://CHANGE-ME/…'` | Step 2 not done. |
| `Set params.bucket in the REQUIRED INPUTS block` | Step 2 not done. |
| `Reference is missing BWA index files` | Step 3. Build the index; do not work around it. |
| `Duplicate sample id(s)` | Step 4. Make each `sample` value unique. |
| `NoSuchFileException: s3://…` | Wrong path, or credentials cannot see that bucket. |
| `Unable to get file attributes` (DEBUG) | Harmless. S3-compatible storage quirk; the run continues. |
| Anything about a Sentieon **license** | Should not happen — the license ships in the container image. Escalate to Carolina Cloud rather than installing one. |
| A task fails then succeeds on retry | Normal. Workers get preempted; up to 3 retries are configured. |

The full log is `.nextflow.log`. Include it when reporting a problem.

## Do not

- Do not edit `main.nf` or `smoke.nf`.
- Do not put credentials in any file in this repository.
- Do not skip the smoke test.
- Do not invent bucket names, paths, or credentials. Ask.
