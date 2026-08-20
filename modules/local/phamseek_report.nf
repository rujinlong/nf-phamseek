process PHAMSEEK_REPORT {
    tag "$meta.id"
    label 'process_single'

    publishDir path: { "${params.outdir}/${meta.id}/report" }, mode: 'copy', pattern: '*.phamseek.*'

    input:
    // INV-NF-18: `bracken` and `l2_stats` are both optional. They are given
    // DISTINCT placeholder filenames *and* staged into separate directories, so
    // two absent inputs can never collide on basename the way a shared NO_FILE
    // placeholder would (that collision is a launch-time hard error, not a
    // warning). Presence is decided with the shell's `basename`, not Groovy's
    // `.name`, because only the former sees the staged path.
    tuple val(meta),
          path(kraken_report),
          path(nanoq_raw),
          path(nanoq_filtered),
          path(l1_stats),
          path(diagnostics),
          path(bracken,  stageAs: 'optional_bracken/*'),
          path(l2_stats, stageAs: 'optional_l2/*')
    // Run-level, so it arrives as a value channel and is reused for every
    // sample. Carries the decoy classes actually found in the database.
    path db_manifest

    output:
    tuple val(meta), path("${meta.id}.phamseek.tsv"),  emit: tsv
    tuple val(meta), path("${meta.id}.phamseek.json"), emit: json
    path "versions.yml",                               emit: versions

    script:
    def sample_type = meta.sample_type ?: 'sample'
    def platform    = meta.platform ?: 'ont'
    def db_label    = params.db_label ?: ''
    """
    BRACKEN_ARG=""
    if [ "\$(basename '${bracken}')" != "NO_BRACKEN" ]; then
        BRACKEN_ARG="--bracken ${bracken}"
    fi

    L2_ARG=""
    if [ "\$(basename '${l2_stats}')" != "NO_L2STATS" ]; then
        L2_ARG="--l2-stats ${l2_stats}"
    fi

    phamseek_report.py \\
        --sample-id ${meta.id} \\
        --sample-type '${sample_type}' \\
        --platform '${platform}' \\
        --kraken-report ${kraken_report} \\
        --nanoq-raw ${nanoq_raw} \\
        --nanoq-filtered ${nanoq_filtered} \\
        --l1-stats ${l1_stats} \\
        --diagnostics ${diagnostics} \\
        --out-tsv ${meta.id}.phamseek.tsv \\
        --out-json ${meta.id}.phamseek.json \\
        --min-reads ${params.min_reads} \\
        --min-rpm ${params.min_rpm} \\
        --db-label '${db_label}' \\
        --db-has-decoy '${params.db_has_decoy}' \\
        --db-manifest ${db_manifest} \\
        --kraken-confidence ${params.kraken2_confidence} \\
        \$BRACKEN_ARG \$L2_ARG

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version 2>&1 | sed 's/^Python //')
    END_VERSIONS
    """

    stub:
    """
    printf 'sample_id\\tsample_type\\ttaxon_name\\ttaxid\\trank\\tis_leaf\\treads\\treads_clade\\trpm_nonhost\\tpct_nonhost\\tnonhost_denominator\\tbracken_est_reads\\tbracken_fraction\\tcall\\tevidence\\tflags\\tnot_for_clinical_diagnosis\\n' \\
        > ${meta.id}.phamseek.tsv
    echo '{"sample_id":"${meta.id}","sample_type":"sample","platform":"ont","candidates":[],"caveats":["stub"],"classification":{},"host_depletion":{},"qc":{},"chimera_diagnostics":{}}' \\
        > ${meta.id}.phamseek.json

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: stub
    END_VERSIONS
    """
}
