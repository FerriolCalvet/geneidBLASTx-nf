/*
*  Geneid module.
*/

// Parameter definitions
params.CONTAINER = "ferriolcalvet/training-modules"
// params.OUTPUT = "geneid_output"
// params.LABEL = ""



/*
 * Defining the output folders.
 */
OutputFolder = "${params.output}"


/*
 * Defining the module / subworkflow path, and include the elements
 */
subwork_folder = "${projectDir}/subworkflows/"

include { UncompressFASTA } from "${subwork_folder}/tools" addParams(OUTPUT: OutputFolder)
include { Index_fai } from "${subwork_folder}/tools" addParams(OUTPUT: OutputFolder)
include { getFASTA } from "${subwork_folder}/tools" addParams(OUTPUT: OutputFolder)


/*
 * Remove some matches from the GFF to make it smaller and avoid redundancy in the introns
 */
process summarize_GFF {

    // // indicates to use as a container the value indicated in the parameter
    // container params.CONTAINER

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    // show in the log which input file is analysed
    tag "${main_matches_name}"

    input:
    path (main_matches)
    val exon_margin

    output:
    path ("${main_matches_name}.modified_exons.gff")

    script:
    main_matches_name = main_matches.BaseName
    """
    sort -k1,1 -k4,5n -k9,9 ${main_matches} | \
              awk '!found[\$1"\t"\$2"\t"\$3"\t"\$4]++' | \
              awk '!found[\$1"\t"\$2"\t"\$3"\t"\$5]++' > ${main_matches}.summarized_matches

    awk -v exmar="${exon_margin}" 'OFS="\t"{print \$1, \$4-exmar, \$5+exmar, \$9\$7}' \
                ${main_matches}.summarized_matches | \
                sort -k1,1 -k4,4 -k2,2n > ${main_matches_name}.modified_exons.gff

    rm ${main_matches}.summarized_matches
    """
}




/*
 * Use a python script for identifying the introns
 */
process pyComputeIntrons {

    // indicates to use as a container the value indicated in the parameter
    container params.CONTAINER

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    // show in the log which input file is analysed
    tag "${main_matches_name}"

    input:
    path (main_matches)
    val min_size
    val max_size

    output:
    path ("${main_matches_name}.introns.gff")

    script:
    main_matches_name = main_matches.BaseName
    """
    python compute_introns.py ${main_matches} \
                              ${main_matches_name}.introns.gff \
                              ${max_size}

    awk '!found[\$1"\t"\$2"\t"\$3"\t"\$4"\t"\$5]++' ${main_matches_name}.introns.gff | \
                 sort -k1,1 -k4,5n > ${main_matches_name}.introns.non_redundant.gff

    """
}




/*
 * Use bedtools to remove the introns overlapping protein matches
 */
process removeProtOverlappingIntrons {

    // indicates to use as a container the value indicated in the parameter
    container "quay.io/biocontainers/bedtools:2.27.1--he513fc3_4"

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    // show in the log which input file is analysed
    tag "${main_matches_name}"

    input:
    path (main_matches)
    path (introns)

    output:
    path ("${introns}.introns.gff")

    script:
    main_matches_name = main_matches.BaseName
    introns_name = introns.BaseName
    """
    bedtools intersect -a ${introns} \
                       -b ${main_matches} \
                       -v > ${introns}.non_overlapping_matches
    """
}


/*
 * Get the initial and transition probability matrices of the introns
 */
process getIntron_matrices {

    // indicates to use as a container the value indicated in the parameter
    container "custom_container"

    // MarkovMatrices.awk // see how can I include this file
    // FastaToTbl

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    // show in the log which input file is analysed
    tag "${introns_name}"

    input:
    path (introns)

    output:
    path ("${introns_name}.5.initial")
    path ("${introns_name}.5.transition")

    script:
    introns_name = introns.BaseName
    """
    FastaToTbl ${introns} > ${introns_name}.tbl

    gawk -f MarkovMatrices-noframe.awk 5 ${introns_name} ${introns_name}.tbl

    sort +1 -2  -o ${introns_name}.5.initial ${introns_name}.5.initial
    sort +1 -2  -o ${introns_name}.5.transition ${introns_name}.5.transition

    rm ${introns_name}.tbl
    """
}

/*
 * Workflow for obtaining the estimates of the intron sequences
 */

workflow intron_workflow {

    // definition of input
    take:
    ref_file
    ref_file_ind
    geneid_param
    hsp_file


    main:

    // // requirements:
    // gffread quay.io/biocontainers/gffread:0.12.7--hd03093a_1
    // python + modules pandas and some others

    gff_reduced = summarizeMatches(hsp_file)

    min_size = 0
    max_size = 10000
    computed_introns = pyComputeIntrons(gff_reduced, min_size, max_size)

    non_overlapping_introns = removeProtOverlappingIntrons(hsp_file, computed_introns)

    introns_seq = getFASTA(non_overlapping_introns, ref_file, ref_file_ind)

    // initial_prob_matrix, transition_prob_matrix = getIntron_matrices(introns_seq)


    emit:
    introns_seq
    // initial_prob_matrix
    // transition_prob_matrix
}
