process HOST_DEPLETION_L2 {
    tag "$meta.id"
    label 'process_high'

    publishDir path: { "${params.outdir}/${meta.id}/qc" },         mode: 'copy', pattern: '*.tsv'
    publishDir path: { "${params.outdir}/${meta.id}/clean_reads" }, mode: 'copy', pattern: '*.clean.fastq.gz'

    input:
    tuple val(meta), path(reads)
    path host_db

    output:
    tuple val(meta), path("${meta.id}.clean.fastq.gz"),      emit: reads
    tuple val(meta), path("${meta.id}.host_removal_l2.tsv"), emit: stats
    path "versions.yml",                                     emit: versions

    script:
    def preset = params.minimap2_preset
    """
    # ------------------------------------------------------------------
    # Locate the host reference inside the staged database directory. A
    # prebuilt .mmi is preferred; a plain FASTA also works (minimap2 indexes it
    # on the fly, which costs a few minutes per sample).
    # ------------------------------------------------------------------
    REF=""
    for cand in ${host_db}/*.mmi ${host_db}/*.fna.gz ${host_db}/*.fa.gz ${host_db}/*.fasta.gz ${host_db}/*.fna ${host_db}/*.fa ${host_db}/*.fasta; do
        if [ -e "\$cand" ]; then REF="\$cand"; break; fi
    done
    if [ -z "\$REF" ]; then
        echo "ERROR: no host reference (*.mmi or FASTA) found in '${host_db}'." >&2
        echo "       Build one with deploy/build_host_index.sh, or pass --skip_host_removal." >&2
        exit 1
    fi

    # ------------------------------------------------------------------
    # Level 2 removes what kraken2 could not. `-f 4` keeps only reads with no
    # alignment at all, so anything that touches the host reference is deleted
    # rather than relabelled.
    #
    # An .mmi built with a different preset than the one used here would be
    # silently honoured by minimap2 (index parameters win), so the preset used
    # at build time and the preset here must match — see deploy/build_host_index.sh.
    # ------------------------------------------------------------------
    minimap2 \\
        -ax ${preset} \\
        -t ${task.cpus} \\
        --secondary=no \\
        "\$REF" \\
        ${reads} \\
      | samtools view -@ ${task.cpus} -bS -f 4 -F 256 - \\
      | samtools fastq -n - \\
      | pigz -p ${task.cpus} > ${meta.id}.clean.fastq.gz

    reads_in=\$(( \$(pigz -dc ${reads} | wc -l) / 4 ))
    reads_kept=\$(( \$(pigz -dc ${meta.id}.clean.fastq.gz | wc -l) / 4 ))
    reads_removed=\$(( reads_in - reads_kept ))

    printf 'sample_id\\treads_to_l2\\treads_kept_l2\\thost_reads_removed_l2\\thost_removed_l2_pct\\thost_reference\\n' \\
        > ${meta.id}.host_removal_l2.tsv
    awk -v s='${meta.id}' -v t="\$reads_in" -v k="\$reads_kept" -v r="\$reads_removed" -v ref="\$(basename "\$REF")" \\
        'BEGIN{ pct = (t>0) ? (100.0*r/t) : 0; printf "%s\\t%d\\t%d\\t%d\\t%.4f\\t%s\\n", s, t, k, r, pct, ref }' \\
        >> ${meta.id}.host_removal_l2.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        minimap2: \$(minimap2 --version 2>&1)
        samtools: \$(samtools --version 2>&1 | head -n1 | sed 's/^samtools //')
    END_VERSIONS
    """

    stub:
    """
    echo -n | gzip > ${meta.id}.clean.fastq.gz
    printf 'sample_id\\treads_to_l2\\treads_kept_l2\\thost_reads_removed_l2\\thost_removed_l2_pct\\thost_reference\\n' \\
        > ${meta.id}.host_removal_l2.tsv
    printf '%s\\t0\\t0\\t0\\t0.0000\\tstub\\n' '${meta.id}' >> ${meta.id}.host_removal_l2.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        minimap2: stub
        samtools: stub
    END_VERSIONS
    """
}
