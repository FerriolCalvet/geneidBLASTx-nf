/*
*  Geneid module.
*/

// Parameter definitions
params.CONTAINER = "ferriolcalvet/geneid-fetching"
// params.OUTPUT = "geneid_output"
// params.LABEL = ""


/*
 * Uncompressing if needed
 */
process UncompressFASTA {

    // where to store the results and in which way
    // publishDir(params.OUTPUT, pattern : '*.fa')

    // // indicates to use as a container the value indicated in the parameter
    // container params.CONTAINER

    // show in the log which input file is analysed
    tag "${ref_to_index}"

    input:
    file (ref_to_index)

    output:
    path ("${main_genome_file}")

    script:
    main_genome_file = ref_to_index.BaseName

    """
    if [ ! -s  ${main_genome_file} ]; then
        echo "unzipping genome ${main_genome_file}.gz"
        gunzip -c ${main_genome_file}.gz > ${main_genome_file};
    fi
    """
    // perl -i -lane 'if (/^>/) { (\$id, \$chr)=\$_=~/^>([\\w|.]+)[\\s\\w]+, [\\w]+: (\\w+)/; print ">".\$chr} else {print}' ${main_genome_file}
    // perl -i -lane 'if (/^>/) { ($id, $chr)=$_=~/^>([\w|.]+)[\s\w]+, chromosome: (\w+)/; print ">".$chr} else {print}' ${main_genome_file}
}



/*
 * Indexing if needed
 */

process Index {

    // where to store the results and in which way
    // publishDir(params.OUTPUT, pattern : '*.fa.i')

    // indicates to use as a container the value indicated in the parameter
    // container "quay.io/biocontainers/exonerate:2.4.0--h7c8e0dd_4"
    container params.CONTAINER

    // show in the log which input file is analysed
    tag "${main_genome_file}"

    input:
    path main_genome_file

    output:
    path ("${main_genome_file}.i")

    script:
    """
    if [ ! -s  ${main_genome_file}.i ]; then
        echo "indexing genome ${main_genome_file}"
        fastaindex -f ${main_genome_file} -i ${main_genome_file}.i
    fi
    """
    // cut -d ' ' -f1 ${main_genome_file}.i >> ${main_genome_file}.list
}



process runGeneid_fetching {

    // where to store the results and in which way
    publishDir(params.OUTPUT, pattern : '*.gff3')

    // indicates to use as container the value indicated in the parameter
    container params.CONTAINER

    // show in the log which input file is analysed
    // tag "${ref}"
    tag "run Geneid ${query}"

    // MAYBE WE CAN ADD SOMETHING ABOUT THE TASK.CPUS HERE ??

    input:
    path(reference_genome_file)
    path(reference_genome_index)
    path(geneid_param)
    path(protein_matches)
    val query

    output:
    path ("${main_genome_file}.*.gff3")

    script:
    main_genome_file = reference_genome_file.BaseName
    query_curated = query
    // we used this before when we were not cleaning the fasta identifiers
    // query_curated = query.toString().tokenize('|').get(1)
    """
    # prepare sequence
    fastafetch -f ${reference_genome_file} -i ${reference_genome_index} -q \"${query}\" > ${main_genome_file}.${query}

    # prepare evidence
    egrep -w \"^${query}\" ${protein_matches} > ${main_genome_file}.${query}.gff
    blast2gff -vg ${main_genome_file}.${query}.gff > ${main_genome_file}.${query}.SR.gff
    sgp_getHSPSR.pl \"${query}\" < ${main_genome_file}.${query}.SR.gff > ${main_genome_file}.${query}.HSP_SR.gff

    rm ${main_genome_file}.${query}.gff
    rm ${main_genome_file}.${query}.SR.gff

    # run Geneid + protein evidence
    geneid -3P ${geneid_param} -S ${main_genome_file}.${query}.HSP_SR.gff ${main_genome_file}.${query} \
                | sed -e 's/geneid_v1.4/geneidblastx/g' | egrep 'CDS' | sort -k4,5n \
                >> ${main_genome_file}.${query}.gff3

    rm ${main_genome_file}.${query}.HSP_SR.gff
    """
    // $projectDir/scripts/sgp_getHSPSR.pl \"${query}\" < ${main_genome_file}.${query}.SR.gff > ${main_genome_file}.${query}.HSP_SR.gff
}


process testBlast2gff {

    // where to store the results and in which way
    publishDir(params.OUTPUT, pattern : '*.gff')

    // indicates to use as container the value indicated in the parameter
    container params.CONTAINER

    // show in the log which input file is analysed
    // tag "${ref}"
    tag "run blast2gff ${query}"

    // MAYBE WE CAN ADD SOMETHING ABOUT THE TASK.CPUS HERE ??

    input:
    path(reference_genome_file)
    path(reference_genome_index)
    path(geneid_param)
    path(protein_matches)
    val query

    output:
    path ("${main_genome_file}*.gff")

    script:
    main_genome_file = reference_genome_file.BaseName
    // we used this before when we were not cleaning the fasta identifiers
    // query_curated = query.toString().tokenize('|').get(1)
    """
    # prepare evidence
    egrep -w \"^${query}\" ${protein_matches} > ${main_genome_file}.${query}.gff
    blast2gff -vg ${main_genome_file}.${query}.gff > ${main_genome_file}.${query}.SR.gff
    """
}


/*
 * Workflow connecting the different pieces
 */

workflow geneid_WORKFLOW {

    // definition of input
    take:
    ref_file
    geneid_param
    hsp_file

    // main part where we connect two modules, indexing and predicting
    main:

    genome_filename = UncompressFASTA(ref_file)
    // genome_filename.subscribe {  println "Got: $it"  }

    index_filename = Index(genome_filename)
    // index_filename.subscribe {  println "Got: $it"  }

    genome_filename.splitFasta( record: [id: true] )
                   // .subscribe {  println "Got: $it"  }
                   .map{x -> x.toString().tokenize(':]').get(1)}
                   .set{ch}
                   // .subscribe {  println "Got: $it"  }
                   // .flatten()


    // ch -> 39 -> 40 -> mitochondrion
    // only process1 reads
    // ch -> mitochondrion
    // process 2 finishes with the download
    // ch -> mitochondrion -> 33 -> W
    // process 1 and 2 read from here

    //
    // ch.view()
    ch.subscribe {  println "Got: $it"  }

    // geneid_param.view()
    // genome_filename.view()
    // index_filename.view()

    // we call the runGeneid_fetching module using the channel for the queries
    // predictions = testBlast2gff(genome_filename,
    //                             index_filename,
    //                             geneid_param,
    //                             hsp_file,
    //                             ch)
    predictions = runGeneid_fetching(genome_filename,
                                      index_filename,
                                      geneid_param,
                                      hsp_file,
                                      ch)


    emit:
    // index_filename
    pred = predictions
}
