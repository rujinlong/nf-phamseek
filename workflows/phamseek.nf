/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    phamseek — Tier 1 (read-level) workflow
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    chopper/nanoq QC -> kraken2 -> level-1 host split -> minimap2 level-2 host
    depletion -> bracken -> per-sample and run-level reports.

    kraken2 runs BEFORE host depletion on purpose: it classifies every read once,
    and that single pass simultaneously produces the taxonomic profile and the
    first (free) pass of host removal.
----------------------------------------------------------------------------------------
*/

include { ONT_QC                 } from '../modules/local/ont_qc'
include { KRAKEN2_READS          } from '../modules/local/kraken2_reads'
include { HOST_SPLIT_L1          } from '../modules/local/host_split_l1'
include { HOST_DEPLETION_L2      } from '../modules/local/host_depletion_l2'
include { BRACKEN                } from '../modules/local/bracken'
include { DB_MANIFEST            } from '../modules/local/db_manifest'
include { PHAMSEEK_REPORT        } from '../modules/local/phamseek_report'
include { PHAMSEEK_SUMMARY       } from '../modules/local/phamseek_summary'
include { brackenAvailable       } from '../subworkflows/local/utils_phamseek_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/local/utils_phamseek_pipeline'

workflow PHAMSEEK {

    take:
    ch_samplesheet // channel: [ meta, fastq ]
    ch_kraken2_db  // value:   path
    ch_host_index  // value:   path

    main:

    ch_versions = Channel.empty()

    // Record which database produced these results, once per run.
    DB_MANIFEST( ch_kraken2_db )
    ch_versions = ch_versions.mix(DB_MANIFEST.out.versions)

    //
    // Long-read QC: chopper filters, nanoq reports the length/quality
    // distribution on both sides of the filter.
    //
    ONT_QC( ch_samplesheet )
    ch_versions = ch_versions.mix(ONT_QC.out.versions.first())

    //
    // One kraken2 pass over every read.
    //
    KRAKEN2_READS( ONT_QC.out.reads, ch_kraken2_db )
    ch_versions = ch_versions.mix(KRAKEN2_READS.out.versions.first())

    //
    // Level 1 host depletion: delete the host subtree using the classification
    // that has already been computed, and collect the chimera diagnostics from
    // the same streaming pass.
    //
    HOST_SPLIT_L1(
        ONT_QC.out.reads
            .join(KRAKEN2_READS.out.output)
            .join(KRAKEN2_READS.out.report)
    )
    ch_versions = ch_versions.mix(HOST_SPLIT_L1.out.versions.first())

    //
    // Level 2 host depletion: align what is left against the host reference.
    // A kraken2 decoy only relabels; only this step guarantees deletion of host
    // sequence the database did not recognise.
    //
    ch_l2_stats = Channel.empty()
    if (!params.skip_host_removal) {
        HOST_DEPLETION_L2( HOST_SPLIT_L1.out.reads, ch_host_index )
        ch_l2_stats = HOST_DEPLETION_L2.out.stats
        ch_versions = ch_versions.mix(HOST_DEPLETION_L2.out.versions.first())
    } else {
        log.warn(
            "--skip_host_removal is set: only the kraken2 level-1 pass ran. Reads from " +
            "the host that the database does not recognise remain in the output. Do not " +
            "share those files outside the institution."
        )
    }

    //
    // Bracken abundance re-estimation, when the database supports it.
    //
    ch_bracken = Channel.empty()
    if (!params.skip_bracken && brackenAvailable()) {
        BRACKEN( KRAKEN2_READS.out.report, ch_kraken2_db )
        ch_bracken  = BRACKEN.out.tsv
        ch_versions = ch_versions.mix(BRACKEN.out.versions.first())
    }

    //
    // Per-sample report. `bracken` and `l2_stats` are optional: `remainder: true`
    // keeps samples that have neither, and the nulls are replaced by DISTINCT
    // placeholder files (INV-NF-18 — two absent optional inputs sharing one
    // NO_FILE basename is a launch-time collision error).
    //
    def no_bracken = file("${projectDir}/assets/NO_BRACKEN", checkIfExists: true)
    def no_l2      = file("${projectDir}/assets/NO_L2STATS", checkIfExists: true)

    ch_report_in = KRAKEN2_READS.out.report
        .join(ONT_QC.out.raw_stats)
        .join(ONT_QC.out.filtered_stats)
        .join(HOST_SPLIT_L1.out.stats)
        .join(HOST_SPLIT_L1.out.diagnostics)
        .join(ch_bracken,  remainder: true)
        .join(ch_l2_stats, remainder: true)
        .map { row ->
            // Taken as a whole list, and its length checked, rather than
            // destructured directly in the closure signature.
            //
            // Verified on Nextflow 24.x: `remainder: true` pads an unmatched
            // entry with null, so the arity is always 8. If a future version
            // returned a SHORT tuple instead, positional destructuring would
            // quietly slide the level-2 stats file into the bracken slot and the
            // report would be built from the wrong file with no error anywhere.
            // This assertion turns that regression into an immediate failure.
            assert row.size() == 8 : "phamseek: expected 8 fields from the report " +
                "join, got ${row.size()}. Nextflow's join(remainder: true) padding " +
                "semantics have changed; the optional bracken / level-2 inputs can no " +
                "longer be matched positionally. Refusing to build a report from " +
                "possibly mismatched files."
            def (meta, report, nraw, nfilt, l1s, diag, brk, l2s) = row
            [ meta, report, nraw, nfilt, l1s, diag, brk ?: no_bracken, l2s ?: no_l2 ]
        }

    // `.first()` turns the single manifest into a value channel, so the report
    // process runs once per sample rather than once in total.
    PHAMSEEK_REPORT( ch_report_in, DB_MANIFEST.out.manifest.first() )
    ch_versions = ch_versions.mix(PHAMSEEK_REPORT.out.versions.first())

    //
    // Run-level summary: one TSV and one self-contained HTML page.
    //
    // The expected sample count travels with the reports so the summary can
    // refuse to emit a partial run. Without it, a sample dropped by any of the
    // mandatory joins above would simply be missing from the summary table, and
    // a clinician reading the report has no way to notice an absent sample.
    PHAMSEEK_SUMMARY(
        PHAMSEEK_REPORT.out.json.map { it[1] }.collect(),
        ch_samplesheet.count()
    )
    ch_versions = ch_versions.mix(PHAMSEEK_SUMMARY.out.versions)

    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'software_versions.yml',
            sort: true,
            newLine: true
        )

    emit:
    summary_tsv  = PHAMSEEK_SUMMARY.out.tsv
    summary_html = PHAMSEEK_SUMMARY.out.html
    versions     = ch_versions
}
