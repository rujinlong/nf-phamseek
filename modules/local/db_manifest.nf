process DB_MANIFEST {
    label 'process_single'

    publishDir "${params.outdir}/summary", mode: 'copy'

    input:
    path kraken2_db

    output:
    path "database_manifest.tsv", emit: manifest
    path "versions.yml",          emit: versions

    script:
    def db_label = params.db_label ?: 'unlabelled'
    """
    # A result is only interpretable against the database that produced it, so
    # the database identity travels with the output. hash.k2d is too large to
    # checksum on every run; its size and mtime plus checksums of the two small
    # files pin down the build unambiguously in practice.
    {
        printf 'key\\tvalue\\n'
        printf 'db_label\\t%s\\n'          '${db_label}'
        printf 'db_has_decoy\\t%s\\n'      '${params.db_has_decoy}'
        printf 'db_path\\t%s\\n'           "\$(readlink -f ${kraken2_db})"
        printf 'kraken2_confidence\\t%s\\n' '${params.kraken2_confidence}'
        printf 'kraken2_version\\t%s\\n'   "\$(kraken2 --version 2>&1 | head -n1 | sed 's/^Kraken version //')"

        for f in hash.k2d opts.k2d taxo.k2d; do
            if [ -e "${kraken2_db}/\$f" ]; then
                printf '%s_bytes\\t%s\\n' "\$f" "\$(stat -Lc %s "${kraken2_db}/\$f")"
                printf '%s_mtime\\t%s\\n' "\$f" "\$(stat -Lc %y "${kraken2_db}/\$f")"
            else
                printf '%s_bytes\\tMISSING\\n' "\$f"
            fi
        done
        for f in opts.k2d taxo.k2d; do
            if [ -e "${kraken2_db}/\$f" ]; then
                printf '%s_md5\\t%s\\n' "\$f" "\$(md5sum "${kraken2_db}/\$f" | cut -d' ' -f1)"
            fi
        done

        # Bracken needs per-read-length k-mer distributions built into the
        # database; record which lengths are available.
        dists=\$(ls ${kraken2_db}/database*mers.kmer_distrib 2>/dev/null | xargs -r -n1 basename | paste -sd, - || true)
        printf 'bracken_kmer_distrib\\t%s\\n' "\${dists:-none}"
    } > database_manifest.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        kraken2: \$(kraken2 --version 2>&1 | head -n1 | sed 's/^Kraken version //')
    END_VERSIONS
    """

    stub:
    """
    printf 'key\\tvalue\\ndb_label\\tstub\\n' > database_manifest.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        kraken2: stub
    END_VERSIONS
    """
}
