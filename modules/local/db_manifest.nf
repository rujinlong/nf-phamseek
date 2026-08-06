process DB_MANIFEST {
    // kraken2-inspect loads the whole database (~8 GB peak for the 8 GB decoy
    // build), so this needs the kraken2 resource label, not process_single.
    label 'process_kraken2'
    maxForks 1

    publishDir "${params.outdir}/summary", mode: 'copy'

    input:
    path kraken2_db

    output:
    path "database_manifest.tsv", emit: manifest
    path "versions.yml",          emit: versions

    script:
    def db_label = params.db_label ?: 'unlabelled'
    """
    # See modules/local/kraken2_reads.nf: an inherited \$KRAKEN2_DB_PATH would
    # otherwise take precedence over the staged relative path.
    unset KRAKEN2_DB_PATH
    KRAKEN2_DB="\$(readlink -f ${kraken2_db})"

    # ------------------------------------------------------------------
    # Decoy detection.
    #
    # Read the DATABASE's taxonomy, never a sample's kraken2 report. A report
    # lists only taxa that actually received reads, so a decoy database
    # classifying a sample with no human reads shows no 9606 node at all --
    # measured, not assumed: a phage-only read set against the decoy build
    # produced zero 9606 lines. Inferring database content from a report would
    # therefore mislabel exactly the samples where host depletion worked.
    # ------------------------------------------------------------------
    DETECTION_METHOD="unavailable"
    INSPECT=""
    if kraken2-inspect --db "\$KRAKEN2_DB" > inspect_full.tsv 2> inspect.err; then
        INSPECT="inspect_full.tsv"
        DETECTION_METHOD="kraken2-inspect"
    elif [ -s "\$KRAKEN2_DB/inspect.txt" ]; then
        # Some distributed databases ship this; better than nothing if the
        # inspect run could not be afforded.
        INSPECT="\$KRAKEN2_DB/inspect.txt"
        DETECTION_METHOD="shipped-inspect.txt"
        echo "WARN: kraken2-inspect failed, using the database's shipped inspect.txt" >&2
        head -3 inspect.err >&2 || true
    else
        # Detection failure must never fail the run: everything is reported as
        # unknown and the report words itself accordingly.
        echo "WARN: could not inspect the database taxonomy; decoy content will be reported as unknown" >&2
        head -3 inspect.err >&2 || true
    fi

    # Emits "<state>\\t<percent-of-minimizers>" for one decoy class.
    # Column 5 of an inspect table is the taxid, column 6 the indented name.
    detect() {
        if [ -z "\$INSPECT" ]; then
            printf 'unknown\\tNA\\n'
            return
        fi
        awk -F'\\t' -v cond="\$1" '
            BEGIN { found = 0 }
            {
                name = tolower(\$6); gsub(/^ +/, "", name)
                taxid = \$5 + 0
                if ((cond == "human"    && taxid == 9606) ||
                    (cond == "bacteria" && taxid == 2) ||
                    (cond == "plasmid"  && (taxid == 45202 || name ~ /^plasmid/))) {
                    printf "detected\\t%s\\n", \$1; found = 1; exit
                }
            }
            END { if (!found) printf "absent\\tNA\\n" }
        ' "\$INSPECT"
    }

    read -r HUMAN_STATE HUMAN_PCT       <<< "\$(detect human)"
    read -r BACTERIA_STATE BACTERIA_PCT <<< "\$(detect bacteria)"
    read -r PLASMID_STATE PLASMID_PCT   <<< "\$(detect plasmid)"

    # ------------------------------------------------------------------
    # A result is only interpretable against the database that produced it, so
    # the database identity travels with the output. hash.k2d is too large to
    # checksum on every run; its size and mtime plus checksums of the two small
    # files pin down the build unambiguously in practice.
    # ------------------------------------------------------------------
    {
        printf 'key\\tvalue\\n'
        printf 'db_label\\t%s\\n'               '${db_label}'
        printf 'db_path\\t%s\\n'                "\$(readlink -f ${kraken2_db})"
        printf 'kraken2_confidence\\t%s\\n'     '${params.kraken2_confidence}'
        printf 'kraken2_version\\t%s\\n'        "\$(kraken2 --version 2>&1 | head -n1 | sed 's/^Kraken version //')"

        printf 'db_has_decoy_declared\\t%s\\n'  '${params.db_has_decoy}'
        printf 'decoy_detection_method\\t%s\\n' "\$DETECTION_METHOD"
        printf 'decoy_human\\t%s\\n'            "\$HUMAN_STATE"
        printf 'decoy_human_pct\\t%s\\n'        "\$HUMAN_PCT"
        printf 'decoy_bacterial\\t%s\\n'        "\$BACTERIA_STATE"
        printf 'decoy_bacterial_pct\\t%s\\n'    "\$BACTERIA_PCT"
        printf 'decoy_plasmid\\t%s\\n'          "\$PLASMID_STATE"
        printf 'decoy_plasmid_pct\\t%s\\n'      "\$PLASMID_PCT"

        for f in hash.k2d opts.k2d taxo.k2d; do
            if [ -e "\$KRAKEN2_DB/\$f" ]; then
                printf '%s_bytes\\t%s\\n' "\$f" "\$(stat -Lc %s "\$KRAKEN2_DB/\$f")"
                printf '%s_mtime\\t%s\\n' "\$f" "\$(stat -Lc %y "\$KRAKEN2_DB/\$f")"
            else
                printf '%s_bytes\\tMISSING\\n' "\$f"
            fi
        done
        for f in opts.k2d taxo.k2d; do
            if [ -e "\$KRAKEN2_DB/\$f" ]; then
                printf '%s_md5\\t%s\\n' "\$f" "\$(md5sum "\$KRAKEN2_DB/\$f" | cut -d' ' -f1)"
            fi
        done

        dists=\$(ls "\$KRAKEN2_DB"/database*mers.kmer_distrib 2>/dev/null | xargs -r -n1 basename | paste -sd, - || true)
        printf 'bracken_kmer_distrib\\t%s\\n' "\${dists:-none}"
    } > database_manifest.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        kraken2: \$(kraken2 --version 2>&1 | head -n1 | sed 's/^Kraken version //')
    END_VERSIONS
    """

    stub:
    """
    {
        printf 'key\\tvalue\\n'
        printf 'db_label\\tstub\\n'
        printf 'db_has_decoy_declared\\t%s\\n' '${params.db_has_decoy}'
        printf 'decoy_detection_method\\tunavailable\\n'
        printf 'decoy_human\\tunknown\\n'
        printf 'decoy_human_pct\\tNA\\n'
        printf 'decoy_bacterial\\tunknown\\n'
        printf 'decoy_bacterial_pct\\tNA\\n'
        printf 'decoy_plasmid\\tunknown\\n'
        printf 'decoy_plasmid_pct\\tNA\\n'
        printf 'bracken_kmer_distrib\\tnone\\n'
    } > database_manifest.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        kraken2: stub
    END_VERSIONS
    """
}
