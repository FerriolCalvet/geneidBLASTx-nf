/*
*  Geneid module.
*/

// Parameter definitions
params.CONTAINER = "ferriolcalvet/python-modules"
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
include { getFASTA as getFASTA2 } from "${subwork_folder}/tools" addParams(OUTPUT: OutputFolder)



/*
 * Merge the DIAMOND BLASTx matches and correct the scores
 * also change format to GFF3
 THIS COULD BE EASILY PARALLELIZABLE BUT I AM NOT SURE
 WHAT IS THE BEST WAY TO DO IT IN NEXTFLOW

 Requirement: blast2gff docker

 */
process mergeMatches {

    // indicates to use as a container the value indicated in the parameter
    container "ferriolcalvet/blast2gff"

    // show in the log which input file is analysed
    tag "${gff_file}"

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    input:
    file (gff_file)

    output:
    path ("${main_output_file}.gff3")

    script:
    main_output_file = gff_file.BaseName

    """
    # get the sequences that have matches
    cut -f1 ${main_output_file}.gff | sort -u > ${main_output_file}.seqs

    # iterate the sequences with matches, running blast2gff for each of them
    while read seq; do
        var=\$(echo "^\$seq")
        egrep -w \$var ${main_output_file}.gff > \${seq}.gff
        blast2gff -vg \${seq}.gff >> ${main_output_file}.SR.gff
        rm \${seq}.gff
    #    break
    done < ${main_output_file}.seqs;

    rm ${main_output_file}.seqs;

    # remove the header rows of all files
    grep -v '#' ${main_output_file}.SR.gff > ${main_output_file}.SR.gff.tmp;
    mv ${main_output_file}.SR.gff.tmp ${main_output_file}.SR.gff;

    # change from GFF to GFF3 making each line a different "transcript"
    grep -v '#' ${main_output_file}.SR.gff | \
            awk '{\$3="CDS";print \$0,"ID="NR";Parent="NR";"}' | \
            sed -e 's/ /\t/g' > ${main_output_file}.gff3

    rm ${main_output_file}.SR.gff;
    """
}


/*
 * Filter HSPs GFF3 by the score of the match
 */
process filter_by_score {

    // // indicates to use as a container the value indicated in the parameter
    // container params.CONTAINER

    // show in the log which input file is analysed
    tag "${gff3_file}"

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    input:
    file (gff3_file)
    val score

    output:
    path ("${main_gff3_file}.over${score}.gff3")

    script:
    main_gff3_file = gff3_file.BaseName
    """
    awk '\$6>=${score}' ${gff3_file} > ${main_gff3_file}.over${score}.gff3
    """
}




/*
 * Evaluate against a reference GFF3
 * Provide as output a TSV with the stats?

  Requirement: gffcompare docker

  ideally I could add some command to parse the output and get SNn and SPn
 */
process evaluateGFF3 {

    // indicates to use as a container the value indicated in the parameter
    container params.CONTAINER

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    // show in the log which input file is analysed
    tag "${gff3_file}"

    input:
    path (reference_gff3)
    path (query_gff3)

    output:
    stdout // not sure this is correct
    path ("${query_gff3}.out.stats")

    script:
    """
    gffcompare -T -r ${reference_gff3} ${query_gff3} -o ${query_gff3}.out
    rm ${query_gff3}.out.loci
    rm ${query_gff3}.out.annotated.gtf
    rm ${query_gff3}.out.combined.gtf
    rm ${query_gff3}.out.tracking
    metricsN=\$(grep 'Base level' ${query_gff3}.out.stats | tr -s ' ' '\t' | cut -f 4,6)
    SNn=\$(echo "\$metricsN" | cut -f1)
    SPn=\$(echo "\$metricsN" | cut -f2)
    printf "\$SNn\t\$SPn\n";
    """
}


/*
 * Find ORFs
 */
process ORF_finder {


    // indicates to use as a container the value indicated in the parameter
    container "quay.io/biocontainers/orfipy:0.0.4--py38h8c62d01_0"

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    // show in the log which input file is analysed
    tag "${seqs_file}"

    input:
    path (seqs_file)
    val min_orf_len

    output:
    path ("${seqs_file_name}_longest.bed")

    script:
    seqs_file_name = seqs_file.BaseName
    """
    orfipy ${seqs_file} --strand f --bed ${seqs_file_name}.bed --longest \
                        --min ${min_orf_len} --between-stops \
                        --outdir .
    rm ${seqs_file_name}.bed
    """
    // # remove log also
    // ls -l *.log | head -1 | xargs -n 1 rm
}

/*
 * ORFs relative coordinates to absolute

 Requirement:
 python modules for the script to run
 sys, pandas

 and have the python script in the container also
 see docker with "sgp_getHSPSR.pl" file for an example on how to do it.
 */
process updateGFFcoords {

    // where to store the results and in which way
    publishDir(params.OUTPUT, mode : 'copy', pattern : '*.gff3')

    // indicates to use as a container the value indicated in the parameter
    container "ferriolcalvet/python-modules"

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    // show in the log which input file is analysed
    tag "${main_genome_file}"

    input:
    path (original_gff3)
    path (relative_coords_file)

    output:
    path ("${original_gff3_basename}.ORFs.gff3")

    script:
    original_gff3_basename = original_gff3.BaseName
    """
    #!/usr/bin/env python

    import pandas as pd

    read_orf_coords = pd.read_csv("${relative_coords_file}", sep='\t', header=None)
    read_gff3_file = pd.read_csv("${original_gff3}", sep='\t', header=None)

    read_orf_coords.columns = ["id", "rel_start", "rel_end", "info", "frame2", "strand_ORF"]
    read_gff3_file.columns = ["chr", "program", "region", "start", "end", "value", "strand", "frame", "id"]
    read_orf_coords.loc[:,"id"] = 'ID='+ read_orf_coords.loc[:,"id"].astype(str) + ';Parent='+ read_orf_coords.loc[:,"id"].astype(str) + ';'

    merged_orf_gff3 = read_gff3_file.merge(read_orf_coords, on='id', how='inner')

    def fix_coords(x):
        if x["strand"] == '+':
            return ( int(x["start"] + x["rel_start"]), int(x["start"] + x["rel_end"]) - 1 )

        return ( int(x["end"] - x ["rel_end"])+ 1, int(x["end"] - x["rel_start"]) )

    fixed_coords = merged_orf_gff3.apply(fix_coords, axis=1)
    fixed_coords = pd.DataFrame(fixed_coords.to_list())
    # print(fixed_coords)

    merged_orf_gff3.loc[:,"start"] = fixed_coords.iloc[:,0]
    merged_orf_gff3.loc[:,"end"]   = fixed_coords.iloc[:,1]

    # print(merged_orf_gff3.columns)
    ORF_coords = merged_orf_gff3[['chr', 'program', 'region', 'start', 'end', 'value', 'strand', 'frame', 'id']]
    ORF_coords.to_csv("${original_gff3_basename}.ORFs.gff3", sep='\t', index=False, header=False)
    """

}



/*
 * Workflow for obtaining the estimates of the exon sequences
 */

workflow cds_workflow {

    // definition of input
    take:
    ref_file
    ref_file_ind
    hsp_file


    main:

    // // requirements:
    // gffcompare only for version 0.11 I am using version 0.12.6 in the cluster, maybe create a new container
    // gffread quay.io/biocontainers/gffread:0.12.7--hd03093a_1
    // python + modules pandas and some others
    // orfipy  quay.io/biocontainers/orfipy:0.0.4--py38h4a32c8e_1
    // (samtools)
    // dependencies of the Geneid training part


    // pass matches through blast2gff
    // change format from gff to GFF3
    original_HSP_gff3 = mergeMatches(hsp_file)

    // filter the HSPs by the score
    score = 200
    filtered_HSPs_gff3 = filter_by_score(original_HSP_gff3, score)

    // report first metrics using gffcompare
    // metrics1 = evaluateGFF3(filtered_HSPs_gff3, reference_gff3)

    // use gffread for obtaining the sequences of the matches
    // if the genome has an index next to it gffread goes much faster
    // samtools faidx genome.fa
    // reference_genome_unc = UncompressFASTA(reference_genome)
    // reference_genome_ind = Index(reference_genome_unc)

    matches_seqs = getFASTA(filtered_HSPs_gff3, ref_file, ref_file_ind)


    // use orfipy for obtaining the longest ORFs of each match
    // use python script for computing the absolute coordinates
    minORF = 100
    hsp_rel_ORFs_coords = ORF_finder(matches_seqs, minORF)

    hsp_abs_ORFs_coords = updateGFFcoords(original_HSP_gff3, hsp_rel_ORFs_coords)

    // evaluate the newly generated GFF3
    // metrics2 = evaluateGFF3(hspORFs_coords, reference_gff3)


    // get the sequences of the ORFs using gffread again
    hspORFs_seqs = getFASTA2(hsp_abs_ORFs_coords, ref_file, ref_file_ind)

    emit:
    hspORFs_seqs

}


/*
 * Use gffread to get the sequence of the introns
 */
process getIntrons_sequence {

    // indicates to use as a container the value indicated in the parameter
    container "quay.io/biocontainers/gffread:0.12.7--hd03093a_1"

    // indicates to use as a label the value indicated in the parameter
    label (params.LABEL)

    // show in the log which input file is analysed
    tag "${introns_name}"

    input:
    path (ref_file)
    path (introns)

    output:
    path ("${introns_name}.fa")

    script:
    main_genome_name = ref_file.BaseName
    introns_name = introns.BaseName
    """
    gffread -x ${introns_name}.fa -g ${ref_file} ${introns}
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
