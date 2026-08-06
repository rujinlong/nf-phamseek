process HOST_SPLIT_L1 {
    tag "$meta.id"
    label 'process_medium'

    publishDir "${params.outdir}/${meta.id}/qc", mode: 'copy', pattern: '*.{tsv,json}'

    input:
    tuple val(meta), path(reads), path(kraken2_output), path(kraken2_report)

    output:
    tuple val(meta), path("${meta.id}.l1.fastq.gz"),           emit: reads
    tuple val(meta), path("${meta.id}.host_removal_l1.tsv"),   emit: stats
    tuple val(meta), path("${meta.id}.read_diagnostics.json"), emit: diagnostics
    path "versions.yml",                                       emit: versions

    script:
    def drop_viral = params.l2_input == 'nonhuman_nonviral' ? '--drop-viral' : ''
    """
    # Level 1 of host depletion reuses the kraken2 pass that has already been
    # paid for: reads in the Homo sapiens subtree are deleted outright. This is
    # a real deletion, not a relabelling — a kraken2 decoy only changes the
    # label, so on its own it would leave human sequence in the intermediate
    # files, any downstream assembly, and the report.
    phamseek_split_reads.py \\
        --kraken-output ${kraken2_output} \\
        --kraken-report ${kraken2_report} \\
        --in-reads ${reads} \\
        --out-reads ${meta.id}.l1.fastq.gz \\
        --stats ${meta.id}.host_removal_l1.tsv \\
        --diagnostics ${meta.id}.read_diagnostics.json \\
        --sample-id ${meta.id} \\
        --host-taxid ${params.host_taxid} \\
        --viral-taxid ${params.viral_taxid} \\
        ${drop_viral}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version 2>&1 | sed 's/^Python //')
    END_VERSIONS
    """

    stub:
    """
    echo -n | gzip > ${meta.id}.l1.fastq.gz
    printf 'sample_id\\treads_in\\thost_reads_removed_l1\\thost_removed_l1_pct\\tviral_reads_l1\\tother_reads_l1\\tunclassified_reads_l1\\treads_to_l2\\thost_taxid_in_db\\n' \\
        > ${meta.id}.host_removal_l1.tsv
    printf '%s\\t0\\t0\\t0.0000\\t0\\t0\\t0\\t0\\tFALSE\\n' '${meta.id}' >> ${meta.id}.host_removal_l1.tsv
    echo '{"sample_id":"${meta.id}","reads_total":0,"pct_at_root":0,"pct_at_internal_node":0,"pct_multitaxon_kmers":0,"mean_dominant_kmer_fraction":0,"dominant_kmer_fraction_hist":[0,0,0,0,0,0,0,0,0,0],"hist_bin_edges":[0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0],"lift_distance_hist":[0,0,0,0,0,0],"lift_distance_bin_labels":["0","1","2","3","4","5+"],"host_taxid_in_db":false}' \\
        > ${meta.id}.read_diagnostics.json

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: stub
    END_VERSIONS
    """
}
