process KRAKEN2_READS {
    tag "$meta.id"
    label 'process_kraken2'

    // Every kraken2 process loads the whole database into RAM, so two
    // concurrent tasks against an 8 GB database need 16 GB. Serialising them is
    // also faster in practice: the second sample hits the page cache instead of
    // re-reading hash.k2d from disk, and classification itself is not the
    // bottleneck (~42M reads/min once loaded).
    maxForks 1

    publishDir "${params.outdir}/${meta.id}/kraken2", mode: 'copy', pattern: '*.report.txt'

    input:
    tuple val(meta), path(reads)
    path kraken2_db

    output:
    tuple val(meta), path("${meta.id}.kraken2.report.txt"),    emit: report
    tuple val(meta), path("${meta.id}.kraken2.output.txt.gz"), emit: output
    path "versions.yml",                                       emit: versions

    script:
    """
    # kraken2 resolves a relative --db against \$KRAKEN2_DB_PATH before the
    # working directory. That variable is commonly set in a bioinformatician's
    # shell profile and is inherited by every task, so a staged database
    # directory named e.g. 'kraken2' silently resolves to a completely
    # different database. Unset it and pass an absolute path.
    unset KRAKEN2_DB_PATH
    KRAKEN2_DB="\$(readlink -f ${kraken2_db})"

    # Single-end: ONT has no read pairs, so there is no --paired here.
    kraken2 \\
        --db "\$KRAKEN2_DB" \\
        --threads ${task.cpus} \\
        --confidence ${params.kraken2_confidence} \\
        --gzip-compressed \\
        --report ${meta.id}.kraken2.report.txt \\
        --output ${meta.id}.kraken2.output.txt \\
        ${reads}

    # A sample where nothing survives QC still has to produce a parsable report.
    touch ${meta.id}.kraken2.report.txt ${meta.id}.kraken2.output.txt
    pigz -p ${task.cpus} ${meta.id}.kraken2.output.txt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        kraken2: \$(kraken2 --version 2>&1 | head -n1 | sed 's/^Kraken version //')
    END_VERSIONS
    """

    stub:
    """
    printf '100.00\\t0\\t0\\tU\\t0\\tunclassified\\n' > ${meta.id}.kraken2.report.txt
    echo -n | gzip > ${meta.id}.kraken2.output.txt.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        kraken2: stub
    END_VERSIONS
    """
}
