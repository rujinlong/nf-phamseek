process PHAMSEEK_SUMMARY {
    label 'process_single'

    // Filtered for the same reason as modules/local/db_manifest.nf: versions.yml
    // must not reach summary/, where two processes would fight over the name.
    publishDir "${params.outdir}/summary", mode: 'copy', pattern: '{phamseek_summary.tsv,phamseek_report.html}'

    input:
    // INV-NF-02 permits a collecting glob on the *input* side of a merge step.
    path per_sample_json, stageAs: 'per_sample/*'
    val expected_samples

    output:
    path "phamseek_summary.tsv",  emit: tsv
    path "phamseek_report.html",  emit: html
    path "versions.yml",          emit: versions

    script:
    def db_label = params.db_label ?: ''
    """
    # A silently short summary is worse than no summary: a reader cannot tell a
    # sample that was never analysed from one that came back negative.
    n_found=\$(ls per_sample/*.json 2>/dev/null | wc -l)
    if [ "\$n_found" -ne "${expected_samples}" ]; then
        echo "ERROR: expected reports for ${expected_samples} sample(s) but found \$n_found." >&2
        echo "       Some samples were dropped between classification and reporting." >&2
        exit 1
    fi

    phamseek_summary.py \\
        --json per_sample/*.json \\
        --out-tsv phamseek_summary.tsv \\
        --out-html phamseek_report.html \\
        --version '${workflow.manifest.version}' \\
        --mode '${params.mode}' \\
        --db-label '${db_label}'

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version 2>&1 | sed 's/^Python //')
    END_VERSIONS
    """

    stub:
    """
    printf 'sample_id\\tsample_type\\ttaxon_name\\ttaxid\\trank\\treads\\trpm_nonhost\\tpct_nonhost\\tcall\\tevidence\\tflags\\tnot_for_clinical_diagnosis\\n' \\
        > phamseek_summary.tsv
    echo '<title>phamseek report</title><p>stub</p>' > phamseek_report.html

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: stub
    END_VERSIONS
    """
}
