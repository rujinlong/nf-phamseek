process DB_FETCH {
    label 'process_single'

    // NO CONTAINER, deliberately.
    //
    // Two reasons. The database is written to --db_dir, an arbitrary host path
    // that Nextflow does not bind into a container: it binds the work directory
    // and staged inputs, and this path is neither. Making it work would need a
    // per-engine containerOptions bind (-B for apptainer, -v for docker), which
    // is a lot of machinery for a step whose only unusual dependency is zstd.
    //
    // And the image is 1.6 GB. Pulling it in order to download the database is
    // backwards: fetching reference data is the first thing anyone does, and the
    // first step should not depend on the later ones.
    container null

    // The script writes straight into --db_dir rather than through the work
    // directory. Routing 16 GB of reference data through work/ and then copying
    // it out would double the disk requirement to save nothing -- fetch_db.sh is
    // idempotent (it verifies what is already there and skips it), so re-running
    // is cheap without Nextflow tracking the payload.
    publishDir "${params.outdir}/pipeline_info", mode: 'copy', pattern: 'db_fetch.log'

    output:
    path "db_fetch.log", emit: log

    script:
    def component = params.db_component ?: 'all'
    """
    "${projectDir}/deploy/fetch_db.sh" \\
        --outdir "${params.db_dir}" \\
        --component ${component} 2>&1 | tee db_fetch.log
    """

    stub:
    """
    echo "stub: would download --component ${params.db_component ?: 'all'} into ${params.db_dir}" > db_fetch.log
    """
}
