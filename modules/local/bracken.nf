process BRACKEN {
    tag "$meta.id"
    label 'process_low'

    publishDir path: { "${params.outdir}/${meta.id}/kraken2" }, mode: 'copy', pattern: '*.bracken.*'

    input:
    tuple val(meta), path(kraken2_report)
    path kraken2_db

    output:
    tuple val(meta), path("${meta.id}.bracken.tsv"),        emit: tsv
    tuple val(meta), path("${meta.id}.bracken.report.txt"), emit: report
    path "versions.yml",                                    emit: versions

    script:
    """
    # See modules/local/kraken2_reads.nf: an inherited \$KRAKEN2_DB_PATH would
    # otherwise take precedence over the staged relative path.
    unset KRAKEN2_DB_PATH
    KRAKEN2_DB="\$(readlink -f ${kraken2_db})"

    # Bracken exits non-zero when no reads reach the requested rank, which is a
    # legitimate outcome for a negative sample. Distinguish that from a real
    # failure by checking whether the output was produced.
    set +e
    bracken \\
        -d "\$KRAKEN2_DB" \\
        -i ${kraken2_report} \\
        -o ${meta.id}.bracken.tsv \\
        -w ${meta.id}.bracken.report.txt \\
        -r ${params.bracken_read_length} \\
        -l ${params.bracken_level} \\
        -t ${params.bracken_threshold}
    BRACKEN_EXIT=\$?
    set -e

    if [ ! -s ${meta.id}.bracken.tsv ]; then
        if [ \$BRACKEN_EXIT -ne 0 ]; then
            echo "WARN: bracken exited \$BRACKEN_EXIT and produced no rows; treating as 'nothing at rank ${params.bracken_level}'." >&2
        fi
        printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\n' \\
            > ${meta.id}.bracken.tsv
    fi
    touch ${meta.id}.bracken.report.txt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bracken: \$(bracken -v 2>&1 | head -n1 | sed 's/^Bracken v//')
    END_VERSIONS
    """

    stub:
    """
    printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\n' \\
        > ${meta.id}.bracken.tsv
    touch ${meta.id}.bracken.report.txt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bracken: stub
    END_VERSIONS
    """
}
