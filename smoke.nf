#!/usr/bin/env nextflow

/*
 * Preflight check. Run this before a real run:
 *   ./nextflow run smoke.nf -c nextflow.config
 *
 * Starts one tiny task to confirm credentials work, a worker is reachable, and
 * the container has Sentieon plus the DNAscope model bundle. Under a minute.
 *
 * The bundle check earns its keep: if the arch-matched .so were missing, a real
 * run would fail in its final step, hours in.
 */

nextflow.enable.dsl = 2

params.sentieon  = '/home/ccloud/sentieon-genomics-202503.02/bin/sentieon'
params.model_dir = '/etc/sentieon/models/SentieonIlluminaWGS2.2.bundle'

process SMOKE {
    cpus   1
    memory '2 GB'
    errorStrategy 'terminate'

    output:
    stdout

    script:
    """
    set -euo pipefail
    fail() { echo "FAIL: \$1" >&2; exit 1; }

    echo "worker:   \$(hostname) (\$(uname -m))"

    [ -x "${params.sentieon}" ] || fail "no sentieon binary at ${params.sentieon}"
    echo "sentieon: \$(${params.sentieon} driver --version 2>&1 | head -1)"
    echo "license:  \${SENTIEON_LICENSE:-<unset>}"

    [ -d "${params.model_dir}" ] || fail "${params.model_dir} is not a directory"

    for f in bwa.model dnascope.model dnascope.model-\$(uname -m).so; do
        [ -s "${params.model_dir}/\$f" ] || fail "missing: ${params.model_dir}/\$f"
        echo "model:    \$f"
    done

    # Existing on disk is not the same as loadable. DNAModelApply dlopen()s the
    # .so in the pipeline's final step, so load it here instead of finding out
    # hours into a real run.
    SO="${params.model_dir}/dnascope.model-\$(uname -m).so"
    \${SENTIEON_PYTHON:-python3} -c "import ctypes,sys; ctypes.CDLL(sys.argv[1])" "\$SO" \
        || fail "\$SO exists but will not dlopen — unresolved library dependency"
    echo "dlopen:   ok"

    echo
    echo "ALL CHECKS PASSED"
    """
}

workflow {

    // Reference check. Launcher-side only — this lists object names, it does
    // not transfer any data, so it is effectively free.
    if( params.fasta && !params.fasta.contains('CHANGE-ME') ) {
        Channel.fromPath("${params.fasta.replaceAll(/\.[^.\/]+$/, '')}*", checkIfExists: true)
            .collect()
            .map { files ->
                def names   = files.collect { it.name }
                def missing = ['.amb', '.ann', '.bwt', '.pac', '.sa', '.fai']
                                .findAll { ext -> !names.any { it.endsWith(ext) } }
                if( missing )
                    error "Reference is missing BWA index files: ${missing.join(', ')}\n" +
                          "Found: ${names.sort().join(', ')}\n" +
                          "A FASTA on its own is not enough. See README.md."
                log.info "reference: ${names.size()} files, index complete"
            }
    }

    SMOKE().view()
}
