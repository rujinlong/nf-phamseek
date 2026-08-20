process ONT_QC {
    tag "$meta.id"
    label 'process_medium'

    publishDir path: { "${params.outdir}/${meta.id}/qc" }, mode: 'copy', pattern: '*.json'

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("${meta.id}.filtered.fastq.gz"), emit: reads
    tuple val(meta), path("${meta.id}.nanoq_raw.json"),    emit: raw_stats
    tuple val(meta), path("${meta.id}.nanoq_filtered.json"), emit: filtered_stats
    path "versions.yml",                                   emit: versions

    script:
    def args = task.ext.args ?: ''
    """
    # Read-length and quality distribution before filtering, so the report can
    # show what the run looked like as it came off the sequencer.
    nanoq --input ${reads} --stats --json > ${meta.id}.nanoq_raw.json

    # chopper reads stdin and writes stdout.
    pigz -dc ${reads} \\
      | chopper \\
            --quality ${params.chopper_min_quality} \\
            --minlength ${params.chopper_min_length} \\
            --threads ${task.cpus} \\
            ${args} \\
      | pigz -p ${task.cpus} > ${meta.id}.filtered.fastq.gz

    nanoq --input ${meta.id}.filtered.fastq.gz --stats --json > ${meta.id}.nanoq_filtered.json

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chopper: \$(chopper --version 2>&1 | sed 's/^chopper //')
        nanoq: \$(nanoq --version 2>&1 | sed 's/^nanoq //')
    END_VERSIONS
    """

    stub:
    """
    echo -n | gzip > ${meta.id}.filtered.fastq.gz
    echo '{"reads":0,"bases":0,"n50":0,"longest":0,"shortest":0,"mean_length":0,"median_length":0,"mean_quality":0,"median_quality":0}' > ${meta.id}.nanoq_raw.json
    echo '{"reads":0,"bases":0,"n50":0,"longest":0,"shortest":0,"mean_length":0,"median_length":0,"mean_quality":0,"median_quality":0}' > ${meta.id}.nanoq_filtered.json

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chopper: stub
        nanoq: stub
    END_VERSIONS
    """
}
