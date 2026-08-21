process KRONA_SAMPLE {
    tag "$meta.id"
    label 'process_single'

    publishDir path: { "${params.outdir}/${meta.id}/krona" }, mode: 'copy', pattern: '*.krona.html'

    input:
    tuple val(meta), path(kraken2_report)

    output:
    tuple val(meta), path("${meta.id}.krona.html"), emit: html
    tuple val(meta), path("${meta.id}.krona.txt"),  emit: text
    path "versions.yml",                            emit: versions

    script:
    """
    # ------------------------------------------------------------------
    # Chart the NON-HOST subtree, not the whole report.
    #
    # In plasma and CSF the report is dominated by Homo sapiens -- around 82%
    # in the runs this pipeline was built on -- which compresses everything the
    # chart exists to show into a sliver too thin to click. Dropping the host
    # subtree also puts the chart on the same denominator as the rest of the
    # report: --min_rpm is already reads per million NON-HOST reads.
    #
    # Deleting the host rows is sufficient and does not distort the parents:
    # kreport2krona.py takes each node's own count from column 3 (reads assigned
    # AT this node) and rebuilds the lineage from the indentation. It never
    # reads the clade totals in column 2, which do still include the host.
    #
    # Everything else is kept, including unclassified reads. In a low-biomass
    # sample the unclassified fraction is itself a finding, and a chart that
    # quietly dropped it would read as a cleaner sample than it is.
    # ------------------------------------------------------------------
    awk -F'\\t' -v host='${params.host_taxid}' '
        # Guard first: a blank or truncated line would make \$(NF-1) index
        # backwards off the start of the record and abort the whole pass.
        NF < 3 { next }
        {
            indent = match(\$NF, /[^ ]/) - 1
            if (dropping) {
                if (indent > drop_indent) { next }   # still inside the host subtree
                dropping = 0
            }
            if (\$(NF-1) + 0 == host) { dropping = 1; drop_indent = indent; next }
            print
        }
    ' ${kraken2_report} > ${meta.id}.nonhost.report.txt

    # --intermediate-ranks is NOT optional here, despite being off by default.
    #
    # Without it kreport2krona.py keeps only the seven standard ranks
    # (D,P,C,O,F,G,S) and silently discards the reads sitting on every other
    # node. On the test sample that is 74 of 330 non-host reads: 38 classified
    # at root, 1 at cellular organisms, and 35 at `plasmids` (rank R2). Those
    # last two are exactly what this pipeline warns about -- root-level
    # assignments are the chimera signal, and plasmid hits are the dominant
    # false-positive source for phage calls -- so a chart that drops them hides
    # the confounders it should be showing. Measured, not assumed; the check
    # below keeps it that way.
    kreport2krona.py \\
        -r ${meta.id}.nonhost.report.txt \\
        -o ${meta.id}.krona.txt \\
        --intermediate-ranks

    # Every non-host read must reach the chart.
    #
    # kreport2krona.py takes each node's own count from column 3, so the charted
    # total has to equal the sum of column 3 over the filtered report. If a
    # future version of KrakenTools changes which nodes it keeps, or the
    # --intermediate-ranks flag is dropped, the chart would still render -- just
    # with reads missing and no indication of it. Fail instead.
    charted=\$(awk -F'\\t' '{ s += \$1 } END { print s + 0 }' ${meta.id}.krona.txt)
    expected=\$(awk -F'\\t' 'NF >= 3 { s += \$3 } END { print s + 0 }' ${meta.id}.nonhost.report.txt)
    if [ "\$charted" -ne "\$expected" ]; then
        echo "ERROR: the Krona chart accounts for \$charted reads but the non-host report holds \$expected." >&2
        echo "       kreport2krona.py is dropping nodes; the chart would understate part of the sample." >&2
        exit 1
    fi

    # A sample where nothing survived QC, or one that is entirely host, leaves
    # an empty file here. ktImportText on an empty input produces a chart that
    # renders as a blank page, which is indistinguishable from a broken run --
    # so say it in the chart instead.
    if [ ! -s ${meta.id}.krona.txt ]; then
        printf '0\\tno_non_host_reads\\n' > ${meta.id}.krona.txt
    fi

    # ktImportText, NEVER ktImportTaxonomy. The latter needs Krona's own NCBI
    # taxonomy build -- hundreds of MB, fetched from the network by
    # ktUpdateTaxonomy.sh -- which would break both the offline promise and the
    # container's self-containedness. kreport2krona.py has already resolved
    # every lineage, so the text importer needs nothing but this file.
    #
    # The output is self-contained: Krona 2.8.1 inlines its JavaScript and
    # embeds its logo as a data: URI. Verified on the generated file -- the only
    # absolute URLs left are two documentation links that a reader has to click.
    ktImportText -o ${meta.id}.krona.html ${meta.id}.krona.txt,${meta.id}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        krona: \$(ktImportText 2>&1 | grep -oE 'KronaTools [0-9.]+' | head -n1 | sed 's/KronaTools //')
    END_VERSIONS
    """

    stub:
    """
    printf '1\\tViruses\\tCaudoviricetes\\n' > ${meta.id}.krona.txt
    echo '<html><title>krona stub</title></html>' > ${meta.id}.krona.html

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        krona: stub
    END_VERSIONS
    """
}
