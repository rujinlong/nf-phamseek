process KRONA_RUN {
    label 'process_single'

    publishDir "${params.outdir}/summary", mode: 'copy', pattern: 'phamseek_krona.html'

    input:
    // INV-NF-02 permits a collecting glob on the *input* side of a merge step.
    path krona_text, stageAs: 'krona/*'

    output:
    path "phamseek_krona.html", emit: html
    path "versions.yml",        emit: versions

    script:
    """
    # One chart holding every sample as its own dataset, switchable from the
    # menu in the top-left of the page. ktImportText takes any number of inputs
    # at once, so the run-level chart costs no more than the per-sample ones.
    #
    # The label after the comma is what the dataset selector shows, so it has to
    # be the sample ID: the staged file names are the only place that survives
    # from the samplesheet to here.
    args=""
    for f in krona/*.krona.txt; do
        [ -e "\$f" ] || continue
        args="\$args \$f,\$(basename "\$f" .krona.txt)"
    done
    if [ -z "\$args" ]; then
        echo "ERROR: no per-sample Krona inputs were staged." >&2
        exit 1
    fi

    # Unquoted on purpose: each element is "<path>,<label>" and the whole string
    # has to split into one argument per dataset. Sample IDs are checked for
    # whitespace when the samplesheet is parsed, so there is nothing to split on
    # inside an element.
    # shellcheck disable=SC2086
    ktImportText -o phamseek_krona.html \$args

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        krona: \$(ktImportText 2>&1 | grep -oE 'KronaTools [0-9.]+' | head -n1 | sed 's/KronaTools //')
    END_VERSIONS
    """

    stub:
    """
    echo '<html><title>krona run stub</title></html>' > phamseek_krona.html

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        krona: stub
    END_VERSIONS
    """
}
