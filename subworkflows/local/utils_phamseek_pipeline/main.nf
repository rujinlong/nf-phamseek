//
// Initialisation and completion for the phamseek pipeline.
//
// This replaces the nf-core `utils_*` subworkflows. phamseek ships one image
// for the whole pipeline rather than one per process, and has no e-mail or
// chat notification surface, so most of that machinery was inert.
//

// nf-schema, not nf-validation: see the `plugins` and `validation` scopes in
// nextflow.config. `paramsHelp` is deliberately NOT imported -- the plugin's
// help cannot fire under the strict syntax parser, and phamseekHelp() below
// renders the same schema itself.
include { validateParameters } from 'plugin/nf-schema'
include { paramsSummaryLog   } from 'plugin/nf-schema'

workflow PIPELINE_INITIALISATION {

    take:
    version         // boolean
    help            // boolean, or the name of a single parameter
    show_hidden     // boolean
    validate_params // boolean
    monochrome_logs // boolean
    outdir          // string
    input           // string: path to samplesheet

    main:

    if (asBool('version', version)) {
        log.info "${workflow.manifest.name} ${workflow.manifest.version}"
        System.exit(0)
    }

    if (helpRequested(help)) {
        log.info phamseekHelp(help, show_hidden, monochrome_logs)
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
        log.info "[phamseek] NOT FOR CLINICAL DIAGNOSIS - phamseek reports read-level evidence only."
    }
}

def phamseekFailureHint() {
    log.error "[phamseek] Pipeline failed. The failing task's work directory is printed above; " +
              "its .command.log and .command.err hold the tool's own error message."
}

//
// phamseek implements the read-level tier only. `--mode full` fails immediately
// rather than running a partial path that would look like a complete answer.
//
def setupMode() {
    return params.mode.toString() == 'setup'
}

//
// Checks for `--mode setup`. A separate function because the setup path skips
// PIPELINE_INITIALISATION entirely -- and therefore skips validateParameters(),
// so nothing else checks these.
//
def validateSetup() {
    if (!params.db_dir) {
        error(
            "--mode setup needs --db_dir <dir>: the directory to download the\n" +
            "  reference databases into. Pass that same path to the analysis run.")
    }
    def component = (params.db_component ?: 'all').toString()
    if (!(component in ['all', 'kraken2', 'host'])) {
        error("--db_component must be 'all', 'kraken2' or 'host'; got '${component}'.")
    }
}

def validateMode() {
    if (params.mode == 'full') {
        error(
            "--mode full is not implemented in phamseek ${workflow.manifest.version}.\n" +
            "  The assembly tier (flye -> geNomad -> CheckV) is planned but deliberately\n" +
            "  not wired up: the target samples are low-biomass plasma and CSF, where\n" +
            "  coverage is normally too low to assemble, and the validated path is\n" +
            "  kraken2 lead detection followed by targeted mapping.\n" +
            "  Re-run with --mode fast (the default)."
        )
    }
    if (params.mode != 'fast') {
        error("--mode must be 'fast', 'setup', or 'full' (which this release rejects); got '${params.mode}'.")
    }
    if (!(params.l2_input in ['all_nonhuman', 'nonhuman_nonviral'])) {
        error("--l2_input must be 'all_nonhuman' or 'nonhuman_nonviral'; got '${params.l2_input}'.")
    }
    // Checked here, not by the schema. `minimum`/`maximum` in JSON Schema apply
    // to a number instance only, and from Nextflow 26.04 a command-line value
    // arrives as a String -- so `--kraken2_confidence 5` would pass the schema
    // (it matches the numeric pattern) and then be handed to kraken2, which
    // silently classifies nothing.
    def conf = params.kraken2_confidence.toString()
    if (!conf.isNumber() || conf.toDouble() < 0 || conf.toDouble() > 1) {
        error(
            "--kraken2_confidence must be a number between 0 and 1; got '${conf}'.\n" +
            "  Leave it at 0.02 for ONT unless you have measured a better value on\n" +
            "  your own data: see --help kraken2_confidence for why raising it costs\n" +
            "  far more recall on long reads than on short ones."
        )
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
    // A renamed parameter, refused rather than ignored. `--skip_bracken false`
    // used to mean "run bracken"; under the new name it is simply unrecognised,
    // and an unrecognised parameter only warns -- so bracken would stay off
    // while the user believed they had switched it on.
    if (params.containsKey('skip_bracken')) {
        error(
            "--skip_bracken was renamed to --run_bracken, with the polarity reversed.\n" +
            "  Bracken is off by default either way; switch it ON with a bare --run_bracken\n" +
            "  (plus --bracken_read_length), and leave the flag out to keep it off."
        )
    }

    // Bracken is off by default because its model assumes one fixed read length,
    // which ONT violates by construction. Whoever turns it back on has to supply
    // the length themselves -- there is no defensible default across ONT runs, and
    // a silently wrong -r would produce plausible numbers rather than an error.
    if (runBracken() && !params.bracken_read_length) {
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

    def kraken2 = descendIntoSingleDatabase(resolveDbPath(params.kraken2_db, 'kraken2'))
    def host    = resolveDbPath(params.host_index, 'host')

    if (workflow.stubRun) {
        return [kraken2: kraken2 ?: no_db, host: host ?: no_db]
    }

    if (!kraken2) {
        error(
            "No kraken2 database given.\n" +
            "  Pass --db_dir <dir> (expects <dir>/kraken2 and <dir>/host), or --kraken2_db <dir>.\n" +
            "  To download a prebuilt pair:\n" +
            "      nextflow run ${workflow.manifest.name} --mode setup --db_dir <dir>"
        )
    }
    if (!kraken2.exists()) {
        error(
            "kraken2 database not found: ${kraken2}\n" +
            "  Check the path for a typo, or download a prebuilt pair into it:\n" +
            "      nextflow run ${workflow.manifest.name} --mode setup --db_dir ${params.db_dir ?: '<dir>'}"
        )
    }
    ['hash.k2d', 'opts.k2d', 'taxo.k2d'].each { f ->
        if (!file("${kraken2}/${f}").exists()) {
            error("kraken2 database ${kraken2} is incomplete: ${f} is missing.")
        }
    }

    if (!skipHostRemoval()) {
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
            error(
                "Host reference directory not found: ${host}\n" +
                "  Download one:\n" +
                "      nextflow run ${workflow.manifest.name} --mode setup --db_component host \\\n" +
                "          --db_dir ${params.db_dir ?: '<dir>'}\n" +
                "  or disable the alignment pass with --skip_host_removal (read what that costs first)."
            )
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
    if (runBracken() && !brackenAvailable()) {
        log.warn(
            "kraken2 database ${kraken2} has no bracken k-mer distributions " +
            "(database<N>mers.kmer_distrib), so bracken will be skipped and the report " +
            "will carry kraken2 read counts only. Build them with bracken-build, or drop " +
            "--run_bracken to silence this."
        )
    }

    return [kraken2: kraken2, host: host ?: no_db]
}

//
// Boolean parameters, read as real Booleans.
//
// Nextflow hands every command-line value to the pipeline as a String, and
// validationLenientMode lets it past schema validation without converting it.
// Groovy then reads the String "false" as TRUE, because a non-empty string is
// truthy -- so `--skip_host_removal false` would silently SKIP level-2 host
// depletion while the parameter summary prints "false". It fails in the
// direction that produces a plausible result rather than an error, which is why
// these are never read through plain Groovy truth.
//
def asBool(name, value) {
    if (value instanceof Boolean) {
        return value
    }
    def s = value.toString().trim().toLowerCase()
    if (s == 'true')  { return true }
    if (s == 'false') { return false }
    error("--${name} must be true or false; got '${value}'.")
}

def runBracken() {
    return asBool('run_bracken', params.run_bracken)
}

def skipHostRemoval() {
    return asBool('skip_host_removal', params.skip_host_removal)
}

def skipKrona() {
    return asBool('skip_krona', params.skip_krona)
}

//
// An explicit --kraken2_db / --host_index wins; otherwise the standard layout
// under --db_dir supplies it.
//
// A module-level function rather than a closure held in a local: the strict
// script parser does not let a closure variable be called like a function
// (`resolve(...)` fails with "`resolve` is not defined").
//
def resolveDbPath(explicit, subdir) {
    def p = explicit ?: (params.db_dir ? "${params.db_dir}/${subdir}" : null)
    return p ? file(p) : null
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
    return p ? descendIntoSingleDatabase(file(p)) : null
}

//
// Accept both database layouts. The documented one nests the database under a
// name -- <db_dir>/kraken2/<db_name>/hash.k2d -- so that several references can
// sit side by side; the flat one puts the .k2d files straight in kraken2/.
//
// preflight.sh accepts both, so the pipeline must too. When it did not, a
// collaborator who followed INSTALL.md exactly got a green preflight and then
// "hash.k2d is missing" from the pipeline: the worst kind of failure, because
// the check that was supposed to catch it had already passed.
//
// Only descends when the choice is unambiguous. Several databases side by side
// is a real setup, and silently picking one of them would be worse than asking.
//
def descendIntoSingleDatabase(dir) {
    if (dir == null || !dir.exists() || file("${dir}/hash.k2d").exists()) {
        return dir
    }
    def nested = dir.listFiles()?.findAll { it.isDirectory() && file("${it}/hash.k2d").exists() }
    if (!nested) {
        return dir            // nothing to descend into; let the caller report it
    }
    if (nested.size() > 1) {
        error(
            "${dir} holds ${nested.size()} kraken2 databases: " +
            nested.collect { it.name }.sort().join(', ') + "\n" +
            "  Pick one explicitly with --kraken2_db ${dir}/<name>."
        )
    }
    return nested[0]
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
            "Sample '${sid}': platform '${platform}' is not supported.\n" +
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
        // Two single-byte reads rather than read(byte[2]): Nextflow's strict
        // script parser has no array-creation syntax. InputStream.read()
        // returns 0-255, or -1 at EOF, so a truncated file compares unequal too.
        def magic = fq.newInputStream().withCloseable { stream -> [stream.read(), stream.read()] }
        if (magic[0] != 0x1f || magic[1] != 0x8b) {
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
      platform     optional, default 'ont' (the only one implemented)
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
            // Fully qualified: the strict script parser has no `import`.
            def yaml = new org.yaml.snakeyaml.Yaml()
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

//
// Written next to the collected kraken2 reports.
//
// Pavian is an interactive R/Shiny application, not a pipeline step: it cannot
// produce a static artefact inside a workflow, so phamseek writes its input and
// leaves the launching to whoever wants it. Someone opening results/ months
// later has no way to know what this directory is for, which is what this file
// is for.
//
def pavianReadme() {
    return """\
    Pavian input
    ============

    Every kraken2 report this run produced, gathered here and named by sample,
    so Pavian can be pointed at one directory instead of at each sample folder
    in turn. Nothing here is generated for Pavian: these are the same files
    published under <sample>/kraken2/.

    Pavian is an interactive R/Shiny application. It is deliberately NOT in the
    phamseek container -- it would drag in R and Shiny for a tool that runs
    outside the workflow anyway. Run it separately:

        docker run --rm -p 5000:5000 -v "\$(pwd)":/data florianbw/pavian

    then open http://localhost:5000, choose "Upload files" -> browse, and pick
    the reports from /data.

    Files
    -----
      <sample>.kraken2.report.txt   the standard six-column kraken2 report
      <sample>.bracken.report.txt   only when the run passed --run_bracken

    Bracken is off by default: its model assumes one fixed read length, which
    Oxford Nanopore reads violate by construction. Pavian's bracken panels will
    therefore be empty unless the run was started with --run_bracken and
    --bracken_read_length. That is this pipeline's configuration, not a broken
    integration.

    The reports are taken BEFORE host depletion, because that is where kraken2
    sits in the pipeline: they include the host reads. The Krona charts in
    ../phamseek_krona.html and <sample>/krona/ show the non-host subtree
    instead, and summary/phamseek_summary.tsv reports abundance per million
    non-host reads.

    NOT FOR CLINICAL DIAGNOSIS.
    """.stripIndent()
}

def phamseekLogo(monochrome_logs = true) {
    // asBool, not plain Groovy truth: `--monochrome_logs false` arrives as the
    // String "false", which is truthy.
    def mono = asBool('monochrome_logs', monochrome_logs)
    def c = mono ? '' : "\033[0;36m"
    def r = mono ? '' : "\033[0m"
    def d = mono ? '' : "\033[2m"
    return """
    ${c}phamseek${r} ${workflow.manifest.version}
    ${d}phage detection in low-biomass clinical Oxford Nanopore metagenomes${r}
    ${d}NOT FOR CLINICAL DIAGNOSIS${r}
    """.stripIndent()
}

/*
========================================================================================
    HELP
========================================================================================
*/

//
// `--help` is rendered by the pipeline, from the same nextflow_schema.json the
// plugin validates against.
//
// Not delegated to nf-schema. Under Nextflow's strict syntax parser (the default
// from 26.04) a bare `--help` reaches params as the String "true" rather than a
// Boolean -- measured on 26.04.3 -- and every nf-schema release reads a String
// there as "print help for the parameter with this name". The plugin therefore
// finds no parameter called "true", prints nothing, and the pipeline runs: the
// user asked for help and got a run. See the `validation` scope in
// nextflow.config.
//
// Rendering it here turns that String into a feature rather than a defect:
// "true" means "print everything", and anything else is taken as a parameter
// name, so `--help` and `--help kraken2_confidence` both work under either
// parser.
//

//
// Was help asked for at all? Distinguished from asBool() because this parameter
// legitimately carries a non-boolean value.
//
def helpRequested(request) {
    if (request instanceof Boolean) {
        return request
    }
    def s = request == null ? '' : request.toString().trim()
    return s != '' && s.toLowerCase() != 'false'
}

//
// null for "the whole parameter list", otherwise the one parameter asked about.
//
def helpTopic(request) {
    if (request instanceof Boolean) {
        return null
    }
    def s = request.toString().trim()
    return s.toLowerCase() == 'true' ? null : s
}

def phamseekHelp(request, show_hidden, monochrome_logs = true) {
    def schema_file = file("${projectDir}/nextflow_schema.json")
    if (!schema_file.exists()) {
        error("Cannot render help: ${schema_file} is missing.")
    }
    // Fully qualified: the strict script parser has no `import`.
    def schema = new groovy.json.JsonSlurper().parseText(schema_file.text)
    def topic  = helpTopic(request)
    return topic == null
        ? helpForAllParameters(schema, asBool('show_hidden', show_hidden), monochrome_logs)
        : helpForOneParameter(schema, topic, monochrome_logs)
}

//
// The parameter groups, in the order `allOf` lists them. A group present in
// $defs but not referenced is still printed, at the end, so a half-finished
// edit to the schema loses documentation rather than hiding it.
//
def helpGroups(schema) {
    def defs = schema['$defs'] ?: schema['definitions'] ?: [:]
    // Taken as the last path segment rather than by regex: the strict script
    // parser rejects an escaped '/' inside a slashy string, and the two possible
    // prefixes ('#/$defs/' and the draft-07 '#/definitions/') differ only there.
    def refs = (schema['allOf'] ?: []).collect {
        def r = it['$ref'].toString()
        r.substring(r.lastIndexOf('/') + 1)
    }
    def names = refs.findAll { defs.containsKey(it) } +
                defs.keySet().findAll { !(it in refs) }
    return names.collect { n -> [name: n] + defs[n] }
}

def helpColors(monochrome_logs) {
    if (asBool('monochrome_logs', monochrome_logs)) {
        return [reset: '', bold: '', dim: '', cyan: '']
    }
    return [reset: "\033[0m", bold: "\033[1m", dim: "\033[2m", cyan: "\033[0;36m"]
}

//
// The first declared type, which the schema states is the semantic one.
//
// Most numeric and boolean parameters are declared as `[<type>, "string"]`,
// because Nextflow 26.04 hands every command-line value to the pipeline as a
// String and the schema has to accept that form. Printing the union would tell
// the reader that --min_reads takes a string, which is not what it means.
//
def helpTypeTag(spec) {
    def t = spec['type']
    def s = (t instanceof List) ? (t.find { it != 'null' } ?: 'string') : (t ?: 'string')
    return "[${s}]"
}

//
// The one-line entry: description, then what the schema constrains it to, then
// the default. Anything longer lives in help_text and is shown by
// `--help <parameter>`.
//
def helpSummaryLine(spec) {
    def parts = [ (spec['description'] ?: '').toString().trim() ]
    if (spec['enum']) {
        parts.add("(accepted: ${spec['enum'].join(', ')})")
    }
    if (spec['default'] != null) {
        parts.add("[default: ${spec['default']}]")
    }
    return parts.findAll { it }.join(' ')
}

def wrapHelpText(text, width, indent) {
    def lines = []
    def line = ''
    text.toString().trim().split(/\s+/).toList().each { w ->
        if (line && line.length() + 1 + w.length() > width) {
            lines.add(line)
            line = w.toString()
        }
        else {
            line = line ? "${line} ${w}" : w.toString()
        }
    }
    if (line) {
        lines.add(line)
    }
    return lines.join("\n" + indent)
}

def helpForAllParameters(schema, show_hidden, monochrome_logs) {
    def c      = helpColors(monochrome_logs)
    def groups = helpGroups(schema)

    // One column width across the whole page, so every description starts in
    // the same place regardless of which group it is in.
    def name_w = 0
    def type_w = 0
    groups.each { grp ->
        (grp['properties'] ?: [:]).each { pname, spec ->
            if (show_hidden || !spec['hidden']) {
                if (pname.length() + 2 > name_w) { name_w = pname.length() + 2 }
                if (helpTypeTag(spec).length() > type_w) { type_w = helpTypeTag(spec).length() }
            }
        }
    }

    def indent = ' ' * (2 + name_w + 2 + type_w + 2)
    def wrap_w = 100 - indent.length()

    def out = new StringBuilder()
    out.append(phamseekLogo(monochrome_logs))
    out.append("\n${c.bold}Typical pipeline command${c.reset}\n\n")
    out.append("  nextflow run rujinlong/nf-phamseek -profile apptainer \\\n")
    out.append("      --input samplesheet.csv --db_dir /path/to/phamseek_db --outdir results\n")

    groups.each { grp ->
        def rows = (grp['properties'] ?: [:]).findAll { pname, spec -> show_hidden || !spec['hidden'] }
        if (!rows) {
            return
        }
        out.append("\n${c.bold}${grp['title'] ?: grp['name']}${c.reset}\n")
        rows.each { pname, spec ->
            out.append("  ${c.cyan}${('--' + pname).padRight(name_w)}${c.reset}  " +
                       "${c.dim}${helpTypeTag(spec).padRight(type_w)}${c.reset}  " +
                       "${wrapHelpText(helpSummaryLine(spec), wrap_w, indent)}\n")
        }
    }

    out.append("\n" + samplesheetHelp())
    out.append("\n")
    out.append("  ${c.cyan}--help <parameter>${c.reset}  the full description of one parameter, " +
               "e.g. --help kraken2_confidence\n")
    out.append("  ${c.cyan}--show_hidden${c.reset}       also list the parameters marked hidden\n")
    return out.toString()
}

def helpForOneParameter(schema, name, monochrome_logs) {
    def c     = helpColors(monochrome_logs)
    def known = []
    def hit   = null
    def group = null
    helpGroups(schema).each { grp ->
        (grp['properties'] ?: [:]).each { pname, spec ->
            known.add(pname.toString())
            if (pname.toString() == name) {
                hit   = spec
                group = grp['title'] ?: grp['name']
            }
        }
    }

    if (hit == null) {
        // A misspelt name must not be answered with the entire parameter list:
        // the user would have to spot that their question went unanswered.
        def near = known.findAll {
            it.contains(name) || name.contains(it) || editDistance(it, name) <= 3
        }.sort()
        return "\nNo such parameter: --${name}\n" +
               (near ? "  Did you mean: ${near.collect { '--' + it }.join(', ')}\n" : '') +
               "  Run --help for the full list of ${known.size()} parameters.\n"
    }

    def out = new StringBuilder()
    out.append("\n${c.cyan}--${name}${c.reset}  ${c.dim}${helpTypeTag(hit)}${c.reset}")
    out.append("  ${c.dim}(${group})${c.reset}\n\n")
    if (hit['default'] != null) {
        out.append("  default   ${hit['default']}\n")
    }
    if (hit['enum']) {
        out.append("  accepted  ${hit['enum'].join(', ')}\n")
    }
    if (hit['minimum'] != null || hit['maximum'] != null) {
        // Compared against null rather than with `?:`: a minimum of 0 is falsy
        // in Groovy, and kraken2_confidence would have advertised its range as
        // "-inf to 1".
        def lo = hit['minimum'] == null ? '-inf' : hit['minimum']
        def hi = hit['maximum'] == null ? '+inf' : hit['maximum']
        out.append("  range     ${lo} to ${hi}\n")
    }
    // Shown only for parameters that are genuinely strings, e.g. --max_memory.
    // On a numeric or boolean parameter the pattern only describes the shape of
    // the string form the schema has to accept (see the `validation` scope in
    // nextflow.config); printing `^(true|false)$` under --run_bracken tells the
    // reader nothing the type did not already say.
    def declared = hit['type'] instanceof List ? hit['type'][0] : hit['type']
    if (hit['pattern'] && declared == 'string') {
        out.append("  pattern   ${hit['pattern']}\n")
    }
    out.append("\n  ${wrapHelpText(hit['description'] ?: '(no description)', 96, '  ')}\n")
    if (hit['help_text']) {
        out.append("\n  ${wrapHelpText(hit['help_text'], 96, '  ')}\n")
    }
    return out.toString()
}

//
// Levenshtein distance, used only to suggest a parameter after a typo.
//
// One rolling row rather than a full matrix: the strict script parser has no
// array-creation syntax, and a list of lists would be the only alternative.
//
def editDistance(a, b) {
    if (!a || !b) {
        return (a ? a.length() : 0) + (b ? b.length() : 0)
    }
    def prev = (0..b.length()).collect { it }
    (1..a.length()).each { i ->
        def cur = [i]
        (1..b.length()).each { j ->
            def cost = a.charAt(i - 1) == b.charAt(j - 1) ? 0 : 1
            cur.add([cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].min())
        }
        prev = cur
    }
    return prev[b.length()]
}
