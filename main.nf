#!/usr/bin/env nextflow

/*
 * Sentieon DNAscope germline variant calling — Carolina Cloud
 *   align -> metrics -> dedup -> DNAscope -> DNAModelApply -> VCF
 *
 * Nothing in this file needs editing. Your inputs live in the REQUIRED INPUTS
 * block at the top of nextflow.config. Then:
 *   ./nextflow run main.nf -c nextflow.config
 */

nextflow.enable.dsl = 2

/*
 * Paths inside the container image, not on your machine. Nextflow pastes them
 * straight into the task script without checking them, which is why they can
 * name directories your computer has never heard of.
 */
params.sentieon  = '/home/ccloud/sentieon-genomics-202503.02/bin/sentieon'
params.model_dir = '/etc/sentieon/models/SentieonIlluminaWGS2.2.bundle'

params.platform  = 'ILLUMINA'
params.pcr_free  = false              // true for PCR-free library prep

// Bare filename of the reference, as staged into each task's work dir.
params.fasta_name = params.fasta ? file(params.fasta).name : null

// ===========================================================================

process SENTIEON_ALIGN {
    tag   "$meta.id"
    cpus  32
    memory '64 GB'
    disk  '200 GB'

    input:
    tuple val(meta), path(fastq_1), path(fastq_2)
    path reference

    output:
    tuple val(meta), path("${meta.id}.sorted.bam"), path("${meta.id}.sorted.bam.bai"), emit: bam

    script:
    def fasta = params.fasta_name
    def rg    = "@RG\\tID:${meta.group}\\tSM:${meta.id}\\tPL:${params.platform}"
    // `|| echo -n 'error'` poisons the SAM stream on bwa failure, so util sort
    // dies loudly instead of writing a truncated BAM.
    """
    ( ${params.sentieon} bwa mem -M -R "${rg}" \\
        -t ${task.cpus} -K 10000000 -x ${params.model_dir}/bwa.model \\
        ${fasta} ${fastq_1} ${fastq_2} || echo -n 'error' ) \\
    | ${params.sentieon} util sort --bam_compression 1 -r ${fasta} \\
        -o ${meta.id}.sorted.bam -t ${task.cpus} --sam2bam -i -
    """
}

// LocusCollector emits the score.txt that Dedup needs; the rest is QC.
process SENTIEON_METRICS {
    tag   "$meta.id"
    cpus  16
    memory '32 GB'
    publishDir path: { "${params.outdir}/${meta.id}/metrics" }, mode: 'copy',
               pattern: '*.{pdf,txt}', saveAs: { it == 'score.txt' ? null : it }

    input:
    tuple val(meta), path(bam), path(bai)
    path reference

    output:
    tuple val(meta), path('score.txt'), path('score.txt.idx'), emit: score
    path '*.pdf'
    path '*_metrics.txt'
    path 'gc_summary.txt'

    script:
    def fasta = params.fasta_name
    """
    ${params.sentieon} driver -r ${fasta} -t ${task.cpus} -i ${bam} \\
        --algo LocusCollector --fun score_info score.txt \\
        --algo MeanQualityByCycle mq_metrics.txt \\
        --algo QualDistribution qd_metrics.txt \\
        --algo GCBias --summary gc_summary.txt gc_metrics.txt \\
        --algo AlignmentStat --adapter_seq '' aln_metrics.txt \\
        --algo InsertSizeMetricAlgo is_metrics.txt

    ${params.sentieon} plot GCBias             -o gc-report.pdf gc_metrics.txt
    ${params.sentieon} plot QualDistribution   -o qd-report.pdf qd_metrics.txt
    ${params.sentieon} plot MeanQualityByCycle -o mq-report.pdf mq_metrics.txt
    ${params.sentieon} plot InsertSizeMetricAlgo -o is-report.pdf is_metrics.txt
    """
}

// Drop --rmdup to mark duplicates instead of removing them.
process SENTIEON_DEDUP {
    tag   "$meta.id"
    cpus  16
    memory '32 GB'
    publishDir path: { "${params.outdir}/${meta.id}/metrics" }, mode: 'copy', pattern: '*.dedup_metrics.txt'

    input:
    tuple val(meta), path(bam), path(bai), path(score), path(score_idx)

    output:
    tuple val(meta), path("${meta.id}.deduped.bam"), path("${meta.id}.deduped.bam.bai"), emit: bam
    path "${meta.id}.dedup_metrics.txt"

    script:
    """
    ${params.sentieon} driver -t ${task.cpus} -i ${bam} \\
        --algo Dedup --rmdup --score_info ${score} \\
        --metrics ${meta.id}.dedup_metrics.txt --bam_compression 1 \\
        ${meta.id}.deduped.bam
    """
}

process SENTIEON_DNASCOPE {
    tag   "$meta.id"
    cpus  32
    memory '64 GB'

    input:
    tuple val(meta), path(bam), path(bai)
    path reference

    output:
    tuple val(meta), path("${meta.id}.dnascope_tmp.vcf.gz"), path("${meta.id}.dnascope_tmp.vcf.gz.tbi"), emit: vcf

    script:
    def fasta = params.fasta_name
    def pcr   = params.pcr_free ? '--pcr_indel_model none' : ''
    """
    ${params.sentieon} driver -r ${fasta} -t ${task.cpus} -i ${bam} \\
        --algo DNAscope ${pcr} --model ${params.model_dir}/dnascope.model \\
        ${meta.id}.dnascope_tmp.vcf.gz
    """
}

// Loads dnascope.model-<arch>.so from beside dnascope.model, so model_dir has
// to be a directory rather than a packed bundle file.
process SENTIEON_DNAMODELAPPLY {
    tag   "$meta.id"
    cpus  16
    memory '32 GB'
    publishDir path: { "${params.outdir}/${meta.id}" }, mode: 'copy'

    input:
    tuple val(meta), path(vcf), path(tbi)
    path reference

    output:
    tuple val(meta), path("${meta.id}.vcf.gz"), path("${meta.id}.vcf.gz.tbi"), emit: vcf

    script:
    def fasta = params.fasta_name
    """
    ${params.sentieon} driver -r ${fasta} -t ${task.cpus} \\
        --algo DNAModelApply --model ${params.model_dir}/dnascope.model \\
        -v ${vcf} ${meta.id}.vcf.gz
    """
}

// ===========================================================================

workflow {

    if( !params.fasta || params.fasta.contains('CHANGE-ME') )
        error "Set params.bucket in the REQUIRED INPUTS block of nextflow.config."

    // The FASTA and every sidecar sharing its stem, staged together.
    ch_reference = Channel.fromPath("${params.fasta.replaceAll(/\.[^.\/]+$/, '')}*", checkIfExists: true)
        .collect()
        .map { files ->
            def names   = files.collect { it.name }
            def missing = ['.amb', '.ann', '.bwt', '.pac', '.sa', '.fai']
                            .findAll { ext -> !names.any { it.endsWith(ext) } }
            if( missing )
                error "Reference is missing BWA index files: ${missing.join(', ')}\n" +
                      "Found: ${names.sort().join(', ')}\n" +
                      "See README.md step 3 for how to build the index."
            return files
        }

    ch_reads = Channel.fromPath(params.input, checkIfExists: true)
        .splitCsv(header: true)
        .map { row ->
            tuple([ id: row.sample, group: (row.group ?: row.sample) ],
                  file(row.fastq_1), file(row.fastq_2))
        }

    // Duplicate ids would silently pair a BAM with another sample's score.txt.
    ch_reads.map { meta, r1, r2 -> meta.id }.toList().map { ids ->
        def dupes = ids.countBy { it }.findAll { k, v -> v > 1 }.keySet()
        if( dupes )
            error "Duplicate sample id(s) in ${params.input}: ${dupes.join(', ')}"
    }

    SENTIEON_ALIGN   ( ch_reads, ch_reference )
    SENTIEON_METRICS ( SENTIEON_ALIGN.out.bam, ch_reference )
    SENTIEON_DEDUP   ( SENTIEON_ALIGN.out.bam.join( SENTIEON_METRICS.out.score ) )
    SENTIEON_DNASCOPE      ( SENTIEON_DEDUP.out.bam, ch_reference )
    SENTIEON_DNAMODELAPPLY ( SENTIEON_DNASCOPE.out.vcf, ch_reference )
}
