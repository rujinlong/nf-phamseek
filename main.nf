#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    rujinlong/phamseek
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Phage detection in low-biomass clinical Oxford Nanopore metagenomes.

    Users are not expected to invoke this directly — `bin/phamseek run` is the
    supported entry point. Github: https://github.com/rujinlong/phamseek
----------------------------------------------------------------------------------------
*/

nextflow.enable.dsl = 2

// INV-NF-01: includes only at file top level.
include { PHAMSEEK                } from './workflows/phamseek'
include { PIPELINE_INITIALISATION } from './subworkflows/local/utils_phamseek_pipeline'
include { PIPELINE_COMPLETION     } from './subworkflows/local/utils_phamseek_pipeline'

workflow {

    main:

    PIPELINE_INITIALISATION (
        params.version,
        params.help,
        params.validate_params,
        params.monochrome_logs,
        params.outdir,
        params.input
    )

    PHAMSEEK (
        PIPELINE_INITIALISATION.out.samplesheet,
        PIPELINE_INITIALISATION.out.kraken2_db,
        PIPELINE_INITIALISATION.out.host_index
    )

    PIPELINE_COMPLETION (
        params.outdir,
        params.monochrome_logs
    )
}
