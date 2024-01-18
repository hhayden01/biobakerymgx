#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    hofflab/biobakerymgx
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Github : https://github.com/hofflab/biobakerymgx
----------------------------------------------------------------------------------------
*/

nextflow.enable.dsl = 2

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATE & PRINT PARAMETER SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { paramsSummaryMap; fromSamplesheet } from 'plugin/nf-validation'

// Check if --input file is empty
ch_input = file(params.input, checkIfExists: true)
if (ch_input.isEmpty()) { error("File provided with --input is empty: ${ch_input.getName()}!") }

// read in samplesheet from --input file
Channel
    .fromSamplesheet("input")
    .multiMap { meta, fastq_1, fastq_2  ->
        fastq_gz: [ meta, [ fastq_1, fastq_2 ] ]
    }
    .set { ch_input }


/*
========================================================================================
    IMPORT MODULES/SUBWORKFLOWS
========================================================================================
*/

include { INITIALISE                    } from './subworkflows/nf-core/initialise/main' // TODO: Update subworkflow
include { FASTQC as FASTQC_RAW          } from './modules/nf-core/fastqc/main'
include { FASTQC as FASTQC_PROCESSED    } from './modules/nf-core/fastqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS   } from './modules/nf-core/custom/dumpsoftwareversions/main'
include { MULTIQC                       } from './modules/nf-core/multiqc/main'


/*
========================================================================================
    IMPORT WORKFLOWS
========================================================================================
*/

include { BIOBAKERYMGX } from './workflows/biobakerymgx'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    NAMED WORKFLOW FOR PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def summary_params = paramsSummaryMap(workflow)

//
// WORKFLOW: Run main hofflab/biobakerymgx analysis pipeline
//
workflow HOFFLAB_BIOBAKERYMGX {

    ch_versions = Channel.empty()

    //
    // SUBWORKFLOW: Initialise workflow
    //
    INITIALISE ( params.version, params.help, params.valid_params )

    //
    // MODULE: Merge replicate reads
    //
    ch_reads_for_cat_branch_fastq_gz = ch_input.fastq_gz
        .map {
            meta, reads ->
                def meta_new = meta - meta.subMap('replicate')
                [ meta_new, reads ]
        }
        .groupTuple()
        .map {
            meta, reads ->
                [ meta, reads.flatten() ]
        }
        .branch {
            meta, reads ->
            // we can't concatenate files if there is not a second run, we branch
            // here to separate them out, and mix back in after for efficiency
            cat: reads.size() > 2
            skip: true
        }

    ch_runmerged_reads_fastq_gz = CAT_FASTQ ( ch_reads_for_cat_branch_fastq_gz.cat ).reads
        .mix( ch_reads_for_cat_branch_fastq_gz.skip )
        .map {
            meta, reads ->
            [ meta, [ reads ].flatten() ]
        }

    ch_versions = ch_versions.mix(CAT_FASTQ.out.versions)

    //
    // MODULE: Analyze read quality
    //
    FASTQC_RAW ( ch_runmerged_reads_fastq_gz )
    ch_versions = ch_versions.mix(FASTQC_RAW.out.versions.first())

    //
    // WORKFLOW: Classify and annotate phage sequences in assemblies
    //
    BIOBAKERYMGX ( ch_runmerged_reads_fastq_gz )
    ch_versions = ch_versions.mix(BIOBAKERYMGX.out.versions)

    //
    // MODULE: Analyze read quality
    //
    FASTQC_PROCESSED ( BIOBAKERYMGX.out.preprocessed_reads_fastq_gz )

    //
    // MODULE: Dump software versions for all tools used in the workflow
    //
    CUSTOM_DUMPSOFTWAREVERSIONS (ch_versions.unique().collectFile(name: 'collated_versions.yml'))

    // obtain MultiQC configs
    ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
    ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
    ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

    // create workflow summary
    workflow_summary    = WorkflowBiobakery.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    // create methods description channel
    methods_description    = WorkflowBiobakery.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description, params)
    ch_methods_description = Channel.value(methods_description)

    // prepare MultiQC input
    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC_RAW.out.zip.collect{it[1]}.ifEmpty([]))

    //
    // MODULE: MultiQC
    //
    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )
    multiqc_report = MULTIQC.out.report.toList()
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN ALL WORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// WORKFLOW: Execute a single named workflow for the pipeline
// See: https://github.com/nf-core/rnaseq/issues/619
//
workflow {
    HOFFLAB_BIOBAKERYMGX ()
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
