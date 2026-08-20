#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    rujinlong/nf-phamseek
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Phage detection in low-biomass clinical Oxford Nanopore metagenomes.

    Github: https://github.com/rujinlong/nf-phamseek

        nextflow run rujinlong/nf-phamseek -profile apptainer \
            --input samplesheet.csv --db_dir /path/to/phamseek_db --outdir results
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
