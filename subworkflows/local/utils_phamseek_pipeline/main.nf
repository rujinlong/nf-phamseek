//
// Initialisation and completion for the phamseek pipeline.
//
// This replaces the nf-core `utils_*` subworkflows. phamseek ships a single
// pixi environment rather than per-process containers, and has no e-mail or
// chat notification surface, so most of that machinery was inert.
//

import org.yaml.snakeyaml.Yaml

include { validateParameters } from 'plugin/nf-validation'
include { paramsHelp         } from 'plugin/nf-validation'
include { paramsSummaryLog   } from 'plugin/nf-validation'

workflow PIPELINE_INITIALISATION {

    take:
    version         // boolean
    help            // boolean
    validate_params // boolean
    monochrome_logs // boolean
    outdir          // string
    input           // string: path to samplesheet

    main:

    if (version) {
        log.info "${workflow.manifest.name} ${workflow.manifest.version}"
        System.exit(0)
    }

    if (help) {
        def cmd = "phamseek run --input samplesheet.csv --db_dir /path/to/phamseek_db --outdir results"
        log.info phamseekLogo(monochrome_logs) + paramsHelp(cmd) + '\n' + samplesheetHelp() + '\n'
        System.exit(0)
    }

    if (validate_params) {
        validateParameters()
    }

    log.info phamseekLogo(monochrome_logs)
    log.info paramsSummaryLog(workflow)

    validateMode()
    def dbs = resolveDatabases()

    emit:
    samplesheet = parseSamplesheet(input)
    kraken2_db  = Channel.value(dbs.kraken2)
    host_index  = Channel.value(dbs.host)
}

workflow PIPELINE_COMPLETION {

    take:
    outdir
    monochrome_logs

    main:

    // Captured into a local: the handler runs long after the workflow body,
    // when the `take:` bindings are gone.
    def out_dir = outdir

    // The body is delegated to a module-level function rather than written
    // inline. Inside an `onComplete` closure declared in a module, the implicit
    // `workflow` object resolves to null; from a function it resolves against
    // the script binding as expected.
    workflow.onComplete {
        phamseekCompletionSummary(out_dir)
    }

    workflow.onError {
        phamseekFailureHint()
    }
}

/*
========================================================================================
    FUNCTIONS
========================================================================================
*/

def phamseekCompletionSummary(out_dir) {
    if (workflow.success) {
        log.info "[phamseek] Done. Report: ${out_dir}/summary/phamseek_report.html"
        log.info "[phamseek] NOT FOR CLINICAL DIAGNOSIS - v0.1 reports read-level evidence only."
    }
}

def phamseekFailureHint() {
    log.error "[phamseek] Pipeline failed. The failing task's work directory is printed above; " +
              "its .command.log and .command.err hold the tool's own error message."
}

//
// v0.1 implements the read-level tier only. `--mode full` fails immediately
// rather than running a partial path that would look like a complete answer.
//
def validateMode() {
    if (params.mode == 'full') {
        error(
            "--mode full is not implemented in phamseek v0.1.\n" +
            "  The assembly tier (flye -> geNomad -> CheckV) is planned but deliberately\n" +
            "  not wired up: the target samples are low-biomass plasma and CSF, where\n" +
            "  coverage is normally too low to assemble, and the validated path is\n" +
            "  kraken2 lead detection followed by targeted mapping.\n" +
            "  Re-run with --mode fast (the default)."
        )
    }
    if (params.mode != 'fast') {
        error("--mode must be 'fast' (or 'full', which v0.1 rejects); got '${params.mode}'.")
    }
    if (!(params.l2_input in ['all_nonhuman', 'nonhuman_nonviral'])) {
        error("--l2_input must be 'all_nonhuman' or 'nonhuman_nonviral'; got '${params.l2_input}'.")
    }
    // Pure parameter checks belong here, not in resolveDatabases(): that function
    // returns early under -stub, so a check placed there never runs in a stub.
    // .toString() is load-bearing: a GString never equals a String, so
    // `"${x}" in ['auto', ...]` is false even when x is exactly 'auto'.
    // Note --db_has_decoy true also arrives as a Boolean, hence the coercion.
    if (!(params.db_has_decoy.toString() in ['auto', 'true', 'false'])) {
        error(
            "--db_has_decoy must be 'auto', 'true' or 'false'; got '${params.db_has_decoy}'.\n" +
            "  'auto' reads the database's own taxonomy and reports each decoy class\n" +
            "  separately; use an explicit value only to override that."
        )
    }
    // Bracken is off by default because its model assumes one fixed read length,
    // which ONT violates by construction. Whoever turns it back on has to supply
    // the length themselves -- there is no defensible default across ONT runs, and
    // a silently wrong -r would produce plausible numbers rather than an error.
    if (!params.skip_bracken && !params.bracken_read_length) {
        error(
            "--bracken_read_length is required when bracken is enabled.\n" +
            "  Bracken re-estimates abundance from a k-mer distribution built for one\n" +
            "  fixed read length; ONT runs have no single such length, so there is no\n" +
            "  safe default. Set it from the median read length of your own run\n" +
            "  (nanoq reports it), or leave bracken off -- kraken2 read counts and RPM\n" +
            "  are reported either way and do not depend on it."
        )
    }
}

//
// Resolve the reference databases. `--db_dir` supplies the standard layout and
// the explicit per-database parameters override it. Checks are skipped under
// -stub, where no database is read.
//
def resolveDatabases() {
    def no_db = file("${projectDir}/assets/no_db")

    def resolve = { explicit, subdir ->
        def p = explicit ?: (params.db_dir ? "${params.db_dir}/${subdir}" : null)
        return p ? file(p) : null
    }

    def kraken2 = resolve(params.kraken2_db, 'kraken2')
    def host    = resolve(params.host_index, 'host')

    if (workflow.stubRun) {
        return [kraken2: kraken2 ?: no_db, host: host ?: no_db]
    }

    if (!kraken2) {
        error(
            "No kraken2 database given.\n" +
            "  Pass --db_dir <dir> (expects <dir>/kraken2 and <dir>/host), or --kraken2_db <dir>."
        )
    }
    if (!kraken2.exists()) {
        error("kraken2 database not found: ${kraken2}")
    }
    ['hash.k2d', 'opts.k2d', 'taxo.k2d'].each { f ->
        if (!file("${kraken2}/${f}").exists()) {
            error("kraken2 database ${kraken2} is incomplete: ${f} is missing.")
        }
    }

    if (!params.skip_host_removal) {
        if (!host) {
            error(
                "Host depletion is enabled but no host reference was given.\n" +
                "  Pass --db_dir <dir> (expects <dir>/host) or --host_index <dir>,\n" +
                "  or disable the alignment pass with --skip_host_removal.\n" +
                "  NOTE: --skip_host_removal leaves only the kraken2 level-1 pass, which\n" +
                "  cannot remove human reads the database does not recognise."
            )
        }
        if (!host.exists()) {
            error("Host reference directory not found: ${host}")
        }
        def refs = host.list().findAll { it ==~ /.*\.(mmi|fna|fa|fasta)(\.gz)?$/ }
        if (!refs) {
            error(
                "No host reference (*.mmi or FASTA) found in ${host}.\n" +
                "  Build one with deploy/build_host_index.sh, or pass --skip_host_removal."
            )
        }
    }

    // Bracken needs per-read-length k-mer distributions built into the database.
    // Their absence is common and recoverable, so it downgrades to a warning and
    // the step is skipped, with the reason recorded in database_manifest.tsv.
    if (!params.skip_bracken && !brackenAvailable()) {
        log.warn(
            "kraken2 database ${kraken2} has no bracken k-mer distributions " +
            "(database<N>mers.kmer_distrib), so bracken will be skipped and the report " +
            "will carry kraken2 read counts only. Build them with bracken-build, or pass " +
            "--skip_bracken to silence this."
        )
    }

    return [kraken2: kraken2, host: host ?: no_db]
}

//
// The kraken2 database location, derived from params alone.
//
// Deliberately a pure function rather than state carried out of
// resolveDatabases(): the workflow body needs the same answer, and mutating the
// params map to communicate it is fragile.
//
def resolveKraken2Db() {
    def p = params.kraken2_db ?: (params.db_dir ? "${params.db_dir}/kraken2" : null)
    return p ? file(p) : null
}

def brackenAvailable() {
    if (workflow.stubRun) {
        return true
    }
    def db = resolveKraken2Db()
    if (!db || !db.exists()) {
        return false
    }
    return db.list().any { it ==~ /database\d+mers\.kmer_distrib/ }
}

//
// Parse and validate the samplesheet.
//
// Relative FASTQ paths resolve against the samplesheet's own directory, not the
// launch directory, so a sheet can sit next to its reads and stay portable.
//
def parseSamplesheet(input) {
    if (!input) {
        error("No samplesheet given. Pass --input <samplesheet.csv>.\n\n" + samplesheetHelp())
    }
    def sheet = file(input)
    if (!sheet.exists()) {
        error("Samplesheet not found: ${input}")
    }
    def base = sheet.parent
    def seen = Collections.synchronizedSet(new HashSet())

    return Channel.fromPath(sheet)
        .splitCsv(header: true, strip: true)
        .map { row -> validateSamplesheetRow(row, base, seen) }
}

def validateSamplesheetRow(row, base, seen) {
    // Declared here rather than at file scope: a top-level `def` in a Nextflow
    // module is not visible from inside that module's functions.
    def valid_platforms    = ['ont']
    def valid_sample_types = ['sample', 'ntc', 'positive_control']

    def cols = row.keySet()
    ['sample_id', 'fastq'].each { c ->
        if (!(c in cols)) {
            error("Samplesheet is missing the required column '${c}'.\n\n" + samplesheetHelp())
        }
    }

    def sid = (row.sample_id ?: '').trim()
    if (!sid) {
        error("Samplesheet has a row with an empty sample_id.")
    }
    if (sid ==~ /.*\s.*/) {
        error("sample_id must not contain whitespace: '${sid}'")
    }
    if (!seen.add(sid)) {
        error("Duplicate sample_id in samplesheet: '${sid}'. Sample IDs must be unique.")
    }

    def platform = ((row.platform ?: 'ont').trim() ?: 'ont').toLowerCase()
    if (!(platform in valid_platforms)) {
        error(
            "Sample '${sid}': platform '${platform}' is not supported in v0.1.\n" +
            "  Only 'ont' is implemented. The QC step (chopper/nanoq), the minimap2\n" +
            "  preset (map-ont) and the single-end kraken2 call are all long-read\n" +
            "  specific; running Illumina data through them would produce numbers\n" +
            "  that look valid and are not."
        )
    }

    def stype = ((row.sample_type ?: 'sample').trim() ?: 'sample').toLowerCase()
    if (!(stype in valid_sample_types)) {
        error(
            "Sample '${sid}': sample_type '${stype}' is not recognised. " +
            "Use one of: ${valid_sample_types.join(', ')}."
        )
    }

    def raw = (row.fastq ?: '').trim()
    if (!raw) {
        error("Sample '${sid}': the fastq column is empty.")
    }
    def fq = raw.startsWith('/') ? file(raw) : file("${base}/${raw}")

    if (!fq.exists()) {
        error("Sample '${sid}': FASTQ not found: ${fq}\n  (relative paths resolve against ${base})")
    }
    if (fq.isDirectory()) {
        error("Sample '${sid}': ${fq} is a directory, not a FASTQ file.")
    }
    if (!fq.canRead()) {
        error("Sample '${sid}': FASTQ is not readable (check permissions): ${fq}")
    }
    if (fq.size() == 0) {
        error("Sample '${sid}': FASTQ is empty: ${fq}")
    }
    if (!(fq.name ==~ /.*\.(fastq|fq)(\.gz)?$/)) {
        error("Sample '${sid}': expected a .fastq/.fq (optionally .gz) file, got ${fq.name}")
    }
    if (fq.name.endsWith('.gz')) {
        def magic = new byte[2]
        fq.newInputStream().withCloseable { it.read(magic) }
        if (magic[0] != (byte) 0x1f || magic[1] != (byte) 0x8b) {
            error("Sample '${sid}': ${fq.name} ends in .gz but is not gzip-compressed (truncated or mislabelled?)")
        }
    }

    def meta = [id: sid, platform: platform, sample_type: stype, single_end: true]
    return [meta, fq]
}

def samplesheetHelp() {
    return """\
    Samplesheet format (CSV, header required)

        sample_id,fastq,platform,sample_type
        plasma_01,reads/plasma_01.fastq.gz,ont,sample
        ntc_01,reads/ntc_01.fastq.gz,ont,ntc

      sample_id    required, unique, no whitespace
      fastq        required; absolute, or relative to the samplesheet's directory
      platform     optional, default 'ont' (the only value implemented in v0.1)
      sample_type  optional, default 'sample'; one of sample | ntc | positive_control
                   A no-template control lets the report flag taxa that also appear
                   in it. phamseek flags, it does not subtract.
    """.stripIndent()
}

//
// Collate the per-process versions.yml files into one YAML document.
//
def softwareVersionsToYAML(ch_versions) {
    return ch_versions
        .unique()
        .map { f ->
            def yaml = new Yaml()
            def parsed = yaml.load(f.text).collectEntries { k, v -> [k.tokenize(':')[-1], v] }
            return yaml.dumpAsMap(parsed).trim()
        }
        .unique()
        .mix(Channel.of("""
            Workflow:
                ${workflow.manifest.name}: ${workflow.manifest.version}
                Nextflow: ${workflow.nextflow.version}
        """.stripIndent().trim()))
}

def phamseekLogo(monochrome_logs = true) {
    def c = monochrome_logs ? '' : "\033[0;36m"
    def r = monochrome_logs ? '' : "\033[0m"
    def d = monochrome_logs ? '' : "\033[2m"
    return """
    ${c}phamseek${r} ${workflow.manifest.version}
    ${d}phage detection in low-biomass clinical Oxford Nanopore metagenomes${r}
    ${d}NOT FOR CLINICAL DIAGNOSIS${r}
    """.stripIndent()
}
