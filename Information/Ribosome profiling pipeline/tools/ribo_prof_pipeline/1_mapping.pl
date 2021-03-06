#!/usr/bin/perl -w

$|=1;

use strict;
use warnings;
use DBI;
use Data::Dumper;
use Getopt::Long;
use v5.10;
use Parallel::ForkManager;
use Cwd;

##############
##Command-line
##############
# ./1_mapping.pl --name mESC_GA --species mouse --ensembl 72 --cores 20 --readtype ribo --unique N --inputfile1 file1 --inputfile2 file2 --igenomes_root IGENOMES_ROOT (--mapper STAR --adaptor CTGTAGGCACCATCAATAGATCGGA --readlength 50 --out_bg_s_untr bg_s_untr --out_bg_as_untr bg_as_untr --out_bg_s_tr bg_s_tr --out_bg_as_tr bg_as_tr --out_sam_untr sam_untr --out_sam_tr sam_tr --out_sqlite sqliteDBName --work_dir getcwd --tmpfolder $TMP)
#./1_mapping.pl --name dme_sORFs --species fruitfly --ensembl 74 --cores 10 --readtype ribo --unique N --inputfile1 e224_em_round2_em.fq --inputfile2 e224_harr_ltm_round2_harr_round2_ltm.fq --igenomes_root /storage/igenomes/ --mapper TopHat2 --adaptor CTGTAGGCACCATCAAT (--readlength 50 --out_bg_s_untr bg_s_untr --out_bg_as_untr bg_as_untr --out_bg_s_tr bg_s_tr --out_bg_as_tr bg_as_tr --out_sam_untr sam_untr --out_sam_tr sam_tr --out_sqlite results_dme_sORFs.db --work_dir getcwd --tmpfolder $TMP)

#For GALAXY
#1_mapping.pl --name "${experimentname}" --species "${organism}" --ensembl "${ensembl}" --cores "${cores}" --readtype $readtype.riboSinPair --unique "${unique}" --mapper "${mapper}" --readlength $readtype.readlength --adaptor $readtype.adaptor --inputfile1 $readtype.input_file1 --inputfile2 $readtype.input_file2 --out_bg_s_untr "${untreat_s_bg}"  --out_bg_as_untr "${untreat_as_bg}" --out_bg_s_tr "${treat_s_bg}" --out_bg_as_tr "${treat_as_bg}" --out_sam_untr "${untreat_sam}" --out_sam_tr "${treat_sam}" --out_sqlite "${out_sqlite}" --igenomes_root "${igenomes_root}"

# get the command line arguments
my ($work_dir,$run_name,$species,$ensemblversion,$cores,$mapper,$readlength,$readtype,$tmpfolder,$adaptorSeq,$unique,$seqFileName1,$seqFileName2,$fastqName,
    $out_bg_s_untr,$out_bg_as_untr,$out_bg_s_tr,$out_bg_as_tr,$out_sam_untr,$out_sam_tr,$out_sqlite,$IGENOMES_ROOT,$ref_loc);

GetOptions(
"inputfile1=s"=>\$seqFileName1,         # the fastq file of the untreated data for RIBO-seq (no,CHX,EMT) or the 1st fastq for single/paired-end RNA-seq                  mandatory argument
"inputfile2=s"=>\$seqFileName2,         # the fastq file of the treated data for RIBO-seq (PUR,LTM,HARR) or the 2nd fastq for paired-end RNA-seq                         mandatory argument
"name=s"=>\$run_name,                   # Name of the run,                                                  mandatory argument
"species=s"=>\$species,                 # Species, eg mouse/human/fruitfly,                                 mandatory argument
"ensembl=i"=>\$ensemblversion,          # Ensembl annotation version, eg 66 (Feb2012),                      mandatory argument
"cores=i"=>\$cores,                     # Number of cores to use for Bowtie Mapping,                        mandatory argument
"readtype=s"=>\$readtype,               # The readtype (ribo, PE_polyA, SE_polyA, PE_total, SE_total)       mandatory argument (default = ribo)
"mapper:s"=>\$mapper,                   # The mapper used for alignment (Bowtie,Bowtie2,STAR,TopHat2)       optional  argument (default = STAR)
"readlength:i"=>\$readlength,           # The readlength (if RiboSeq take 50 bases),                        optional  argument (default = 50)
"adaptor:s"=>\$adaptorSeq,              # The adaptor sequence that needs to be clipped with fastx_clipper, optional  argument (default = CTGTAGGCACCATCAATAGATCGGAAGA) => Ingolia paper (for ArtSeq = AGATCGGAAGAGCACACGTCTGAACTCC)
"unique=s" =>\$unique,                  # Retain the uniquely (and multiple) mapping reads (Y or N),        mandatory argument
"tmp:s" =>\$tmpfolder,                  # Folder where temporary files are stored,                          optional  argument (default = $TMP or $CWD/tmp env setting)
"work_dir:s" =>\$work_dir,              # Working directory ,                                               optional  argument (default = $CWD env setting)
"out_bg_s_untr:s" =>\$out_bg_s_untr,    # Output file for sense untreated count data (bedgraph)             optional  argument (default = untreat_sense.bedgraph)
"out_bg_as_untr:s" =>\$out_bg_as_untr,  # Output file for antisense untreated count data (bedgraph)         optional  argument (default = untreat_antisense.bedgraph)
"out_bg_s_tr:s" =>\$out_bg_s_tr,        # Output file for sense treated count data (bedgraph)               optional  argument (default = treat_sense.bedgraph)
"out_bg_as_tr:s" =>\$out_bg_as_tr,      # Output file for antisense treated count data (bedgraph)           optional  argument (default = treat_antisense.bedgraph)
"out_sam_untr:s" =>\$out_sam_untr,      # Output file for alignments of untreated data (sam)                optional  argument (default = untreat.sam)
"out_sam_trs:s" =>\$out_sam_tr,         # Output file for alignments of treated data (sam)                  optional  argument (default = treat.sam)
"out_sqlite:s" =>\$out_sqlite,          # sqlite DB output file                                             optional  argument (default = results.db)
"igenomes_root=s" =>\$IGENOMES_ROOT     # IGENOMES ROOT FOLDER                                              mandatory argument
);


###########################################################################
#Check all input variable and/or get default values and set extra variables
###########################################################################

my $CWD             = getcwd;
my $HOME            = $ENV{'HOME'};
$IGENOMES_ROOT      = ($ENV{'IGENOMES_ROOT'}) ? $ENV{'IGENOMES_ROOT'} : $IGENOMES_ROOT;
print "The following igenomes folder is used                    : $IGENOMES_ROOT\n";
my $TMP             = ($ENV{'TMP'}) ? $ENV{'TMP'} : ($tmpfolder) ? $tmpfolder : "$CWD/tmp"; # (1) get the TMP environment variable, (2) get the $tmpfolder variable, (3) get current_working_dir/tmp
print "The following tmpfolder is used                          : $TMP\n";
#my $NSLOTS  = $ENV{'NSLOTS'};

#Check if tmpfolder exists, if not create it...
if (!-d "$TMP") {
    system ("mkdir ". $TMP);
}

# comment on these
if ($work_dir){
    print "Working directory                                        : $work_dir\n";
} else {
    $work_dir = $CWD;
    print "Working directory                                        : $work_dir\n";
}
if ($seqFileName1){
    print "the fastq file of the untreated data for RIBO-seq (no,CHX,EMT) or the 1st fastq for single/paired-end RNA-seq                               : $seqFileName1\n";
} else {
    die "\nDon't forget to pass the FastQ file for untreated RIBO-seq or single or first paired-end RNA-seq using the --file or -f argument!\n\n";
}
if ($seqFileName2){
    print "the fastq file of the treated data for RIBO-seq (PUR,LTM,HARR) or the 2nd fastq for paired-end RNA-seq                                      : $seqFileName2\n";
} elsif (!defined($seqFileName2) && $readtype eq 'ribo') {
    die "\nDon't forget to pass the FastQ file for treated RIBO-seq (PUR,LTM,HARR) or 2nd fastq for paired-end RNA-seq using the --file or -f argument!\n\n";
}
if ($IGENOMES_ROOT){
    print "the igenomes_root folder used is                         : $IGENOMES_ROOT\n";
} else {
    die "\nDon't forget to pass the igenomes_root folder --igenomes_root or -ig argument!\n\n";
}
if ($run_name){
    print "Run name                                                 : $run_name\n";
} else {
    die "\nDon't forget to pass the Run Name using the --name or -n argument!\n\n";
}
if ($species){
    print "Species                                                  : $species\n";
} else {
    die "\nDon't forget to pass the Species name using the --species or -sp argument!\n\n";
}
if ($ensemblversion){
    print "Ensembl Version                                          : $ensemblversion\n";
} else {
    die "\nDon't forget to pass the Ensembl Version using the --ensembl or -ens argument!\n\n";
}
if ($cores){
    print "Number of cores to use for  mapping                       : $cores\n";
} else {
    die "\nDon't forget to pass number of cores to use for mapping using the --cores or -c argument!\n\n";
}
if ($readtype){
    print "readtype                                                 : $readtype\n";
} else {
    die "\nDon't forget to pass the read type using the --readtype or -r argument!\n\n";
}
if ($adaptorSeq){
    print "The adaptor sequence to be clipped with fastx_clipper    : $adaptorSeq\n";
} else {
    #Choose default value for AdaptorSeq
    $adaptorSeq = "CTGTAGGCACCATCAATAGATCGGAAGA";
    print "The adaptor sequence to be clipped with fastx_clipper    : $adaptorSeq\n";
}
if ($readlength){
    print "The readLength (for RiboSeq it should be set to 36)      : $readlength\n";
} else {
    #Choose default value for readlength
    $readlength = 36;
    print "The readLength (for RiboSeq it should be set to 36)      : $readlength\n";
}
if ($mapper){
    print "The mapper used is                                       : $mapper\n";
} else {
    #Choose default value for mapper
    $mapper = "STAR";
    print "The mapper used is                                       : $mapper\n";
}
if ($unique){
    print "Unique mapped reads                                      : $unique\n";
} else {
    die "\nDon't forget to pass the unique or multiple read retention parameter --unique or -u argument!\n\n";
}

# Create output directory
system "mkdir -p ".$work_dir."/output/";


if (!defined($out_bg_s_untr))  {$out_bg_s_untr     = $work_dir."/output/untreat_sense.bedgraph";}
if (!defined($out_bg_as_untr)) {$out_bg_as_untr    = $work_dir."/output/untreat_antisense.bedgraph";}
if (!defined($out_bg_s_tr))    {$out_bg_s_tr       = $work_dir."/output/treat_sense.bedgraph";}
if (!defined($out_bg_as_tr))   {$out_bg_as_tr      = $work_dir."/output/treat_antisense.bedgraph";}
if (!defined($out_sam_untr))   {$out_sam_untr      = $work_dir."/".$mapper."/fastq1/untreat.sam";}
if (!defined($out_sam_tr))     {$out_sam_tr        = $work_dir."/".$mapper."/fastq2/treat.sam";}
if (!defined($out_sqlite))     {$out_sqlite        = $work_dir."/SQLite/results.db";}

#ADDED FOR TEST ISSUES
my $phix = "Y";
my $clusterPhoenix = "N";
my $bowtie2Setting = "local"; # Or "end-to-end"
my $prev_mapper = ($mapper eq "STAR") ? 'STAR' : "Bowtie2"; # For STAR runs     => prev_mapper = "STAR",
                                                            # For TopHat2 runs  => prev_mapper = "Bowtie2" (prev_mapper is used for Phix and rRNA mapping)

#$prev_mapper = "Bowtie2";
print "Phix/rRNA mapper                                         : $prev_mapper\n";
#Set program run_name
my $run_name_short = $run_name;
$run_name = $run_name."_".$mapper."_".$unique."_".$ensemblversion;

#Conversion for species terminology
my $spec = ($species eq "mouse") ? "Mus_musculus" : ($species eq "human") ? "Homo_sapiens" : ($species eq "arabidopsis") ? "Arabidopsis_thaliana" : ($species eq "fruitfly") ? "Drosophila_melanogaster" : "";
my $spec_short = ($species eq "mouse") ? "mmu" : ($species eq "human") ? "hsa" : ($species eq "arabidopsis") ? "ath" : ($species eq "fruitfly") ? "dme" : "";
#Old mouse assembly = NCBIM37, new one is GRCm38
my $assembly = ($species eq "mouse" && $ensemblversion >= 70 ) ? "GRCm38"
: ($species eq "mouse" && $ensemblversion < 70 ) ? "NCBIM37"
: ($species eq "human") ? "GRCh37"
: ($species eq "arabidopsis") ? "TAIR10"
: ($species eq "fruitfly") ? "BDGP5" : "";

#my $taxid = ($species eq "mouse") ? 10090 : ($species eq "human") ? 9606 : "";
#my $specEns = ($species eq "mouse") ? "mus_musculus" : ($species eq "human") ? "homo_sapiens" : "";


#Names for STAR/Bowtie2/Bowtie Indexes
#rRNA
my $IndexrRNA = $spec_short."_rRNA_seqs";
#Phix
my $IndexPhix = "phix";
#Genome
my $IndexGenome = "genome";
#cDNA
my $IndexCDNA = $spec.".".$assembly.".".$ensemblversion.".cdna.all";

#For STAR-Genome
my $readlengthMinus = $readlength - 1;
my $ensemblversionforStar = ($species eq "mouse" && $ensemblversion >= 70) ? "70" : $ensemblversion;
my $STARIndexGenomeFolder = $spec_short.".".$assembly.".".$ensemblversionforStar.".".$IndexGenome.".".$readlengthMinus."bpOverhang";


#Get executables
my ($bowtie_loc,$bowtie2_loc,$tophat2_loc,$STAR_loc,$sqlite_loc,$samtools_loc,$fastx_clip_loc,$fastx_trim_loc);
#if ($clusterPhoenix eq "Y") {
#General settings for cluster Phoenix
 $bowtie_loc = "bowtie";
 $bowtie2_loc = "bowtie2";
 $tophat2_loc = "tophat2";
 $STAR_loc = "STAR";
 $sqlite_loc = "sqlite3";
 $samtools_loc = "samtools";
 $fastx_clip_loc = "fastx_clipper";
 $fastx_trim_loc = "fastx_trimmer";
#} else {
# $bowtie_loc = "/usr/bin/bowtie";
# $bowtie2_loc = "/usr/share/bowtie2/bowtie2";
# $tophat2_loc = "/usr/share/tophat2/tophat2";
# $STAR_loc = "/usr/share/STAR/STAR";
# $sqlite_loc = "/usr/bin/sqlite3";
# $samtools_loc = "/usr/bin/samtools";
# $fastx_clip_loc = "/data/gerbenm/test/bin/fastx_clipper";
# $fastx_trim_loc = "/data/gerbenm/test/bin/fastx_trimmer";
#}

my $mapper_loc = ($mapper eq "Bowtie1") ? $bowtie_loc
: ($mapper eq "Bowtie2") ? $bowtie2_loc
: ($mapper eq "TopHat2") ? $tophat2_loc
: ($mapper eq "STAR") ? $STAR_loc
: "" ;


#####Locations of rRNA databases and STAR indexes######
#####Dependent on environment, Aramis vs. Phoenix######
my $STAR_ref_loc = ($clusterPhoenix eq "Y") ? $HOME."/STARIndex/" : $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Sequence/STARIndex/";
my $rRNA_fasta   = ($clusterPhoenix eq "Y") ? $HOME."/STARIndex/".$IndexrRNA.".fasta" : $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Sequence/AbundantSequences/".$IndexrRNA.".fasta";
my $phix_fasta   = ($clusterPhoenix eq "Y") ? $HOME."/STARIndex/".$IndexPhix.".fa" : $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Sequence/AbundantSequences/".$IndexPhix.".fa";
my $cDNA_fasta   = ($clusterPhoenix eq "Y") ? $HOME."/STARIndex/".$IndexCDNA.".fa" : $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Sequence/AbundantSequences/".$IndexCDNA.".fa";

my $chromosome_sizes = $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Annotation/Genes/ChromInfo.txt";

########################
#### Initiate results DB
########################

# Create SQLite DB for runName and create connection
my $db_sqlite_results  = $out_sqlite;
#my $db_sqlite_results  = "TCGA_breast_results.db";

system "mkdir -p $work_dir/SQLite";
my $cmd = $sqlite_loc." ".$db_sqlite_results." \"PRAGMA auto_vacuum=1\"";
if (! -e $db_sqlite_results){system($cmd);}

# Sqlite Ensembl
my $dsn_sqlite_results = "DBI:SQLite:dbname=$db_sqlite_results";
my $us_sqlite_results  = "";
my $pw_sqlite_results  = "";

# Store input arguments
store_input_vars($dsn_sqlite_results,$us_sqlite_results,$pw_sqlite_results,$run_name_short,$ensemblversion,$species,$mapper,$unique,$adaptorSeq,$readlength,$readtype,$IGENOMES_ROOT,$cores);


############
## MAPPING
############
# Print/stati
print "Mapping sequences!\n";

my $stat_file;
# Dependent on RIBO-seq or RNA-seq run one has to iterate 2 times (RIBO-seq, both untreated and treated, or just once (RNA-seq).
# For paired-end reads the read files are passed as comma-separated list.
my @loopfastQ;
if ($readtype eq 'ribo') {
    @loopfastQ = ($seqFileName1,$seqFileName2);
}
else {
    if ($readtype =~ m/PE/) {
        my $concatfastQ = $seqFileName1.",".$seqFileName2;
        @loopfastQ = ($concatfastQ);
    } else {
        @loopfastQ = ($seqFileName1);
    }
}


# Start loop, create numeric fastq filename to give along to subroutines, next to fastq file
my $cnt=0;
foreach (@loopfastQ) {
    $cnt++;
    #if ($cnt == 2) { exit; }
    my $fastqName = "fastq".$cnt;
    
    # Init statistics
    $stat_file=$run_name.".".$fastqName.".statistics.txt";
    system("touch ".$stat_file);
    
    if ($mapper eq "Bowtie1") {
        map_bowtie($_,$fastqName);
    }
    elsif ($mapper eq "Bowtie2") {
        map_bowtie2($_,$fastqName);
    }
    elsif ($mapper eq "TopHat2") {
        my $start = time;
        if ($readtype eq "ribo") {
            map_topHat2_ribo($_,$fastqName);
            RIBO_parse_store($_,$fastqName); # Only A-site parsing if RIBO-seq
        }
        my $end = time - $start;
        printf("runtime TopHat against genomic: %02d:%02d:%02d\n\n",int($end/3600), int(($end % 3600)/60), int($end % 60));
    }
    elsif ($mapper eq "STAR") {
        my $start = time;
        if ($readtype eq "ribo") {
            map_STAR_ribo($_,$fastqName);
            RIBO_parse_store($_,$fastqName); # Only A-site parsing if RIBO-seq
        }
        my $end = time - $start;
        printf("runtime STAR against genomic: %02d:%02d:%02d\n\n",int($end/3600), int(($end % 3600)/60), int($end % 60));
    }
    # Store statistics in DB
    store_statistics($stat_file,$dsn_sqlite_results,$us_sqlite_results,$pw_sqlite_results);
}


############
# THE SUBS #
############

sub map_bowtie {

    # Catch
    my $seqFile = $_[0];
    my $seqFileName = $_[1];
    
    my $mismatch = 2;   # From Nature Protocol Paper Ingolia (for Bowtie1)
    my $seed = 25;      # From Nature Protocol Paper Ingolia (for Bowtie1)
    
    # Print
    print "   BOWTIE used for mapping----------------------------------\n";
    print "   Mapping $seqFileName\n";
    
    # Prepare
    my $directory = $work_dir."/".$mapper."/".$seqFileName."/";
    system "mkdir -p $directory";
    my ($fasta,$command,$full_command);
    
    ############################################################################
    #Map to rrna first, cDNA second (non-unique), afterwards to genomic (unique)
    ############################################################################
    
    # Get input fastq file
    #$fasta = $work_dir."/fastq/$seqFileName".".fastq";
    $fasta = $seqFile;
    
    ###### Clip and Trim sequence
    print "     Clipping $seqFileName"."\n";
    
    my $adapter = $adaptorSeq;
    #my $clip_command = $fastx_clip_loc." -Q33 -a ".$adapter." -l 20 -c -n –v -i ".$work_dir."/fastq/$seqFileName".".fastq -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
    my $clip_command = $fastx_clip_loc." -Q33 -a ".$adapter." -l 20 -c -n –v -i ".$fasta." -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";

    #print "     ".$clip_command."\n";
    system ($clip_command);
    print "     Trimming $seqFileName"."\n";
    #print "     ".$fastx_trim_loc." -Q33 -f 2  –v -i ".$work_dir."/fastq/$seqFileName"."_clip.fastq -o ".$work_dir."/fastq/$seqFileName"."_trim.fastq\n";
    system ($fastx_trim_loc." -Q33 -f 2  –v -i ".$work_dir."/fastq/$seqFileName"."_clip.fastq -o ".$work_dir."/fastq/$seqFileName"."_trim.fastq");
    
    ###### Map against rRNA db
    # Check rRNA Index
    check_Bowtie_index($IndexrRNA,$mapper);
    # Build command
    $ref_loc = get_ref_loc($mapper);
    print "     Mapping against rRNA $seqFileName"."\n";
    $command = $mapper_loc." -p ".$cores." --sam --seedlen 23 --al ".$work_dir."/fastq/$seqFileName"."_rrna.fq --un ".$work_dir."/fastq/$seqFileName"."_norrna.fq ".$ref_loc."".$IndexrRNA." ".$work_dir."/fastq/$seqFileName"."_trim.fastq>/dev/null";
    #print "     $command\n";
    # Run
    system($command);
    # Print
    print "   Finished rRNA mapping $seqFileName"." with seedlength 23\n";
    # Process statistics
    system("wc ".$work_dir."/fastq/$seqFileName"."_trim.fastq >> ".$stat_file);
    system("wc ".$work_dir."/fastq/$seqFileName"."_rrna.fq >> ".$stat_file);
    system("wc ".$work_dir."/fastq/$seqFileName"."_norrna.fq >> ".$stat_file);
    
    my $fasta_norrna = $work_dir."/fastq/$seqFileName"."_norrna.fq";
    
    
    ###### Map against cDNA
    # Check cDNA Index
    check_Bowtie_index($IndexCDNA,$mapper);
    # Build command
    print "     Mapping against cDNA $seqFileName"."\n";
    $command = "-l ".$seed." -n ".$mismatch." -p ".$cores." -m 255 --norc --best --strata --phred33-quals --quiet --al ".$directory."$seqFileName"."_".$seed."_cDNA_hit --un ".$directory."$seqFileName"."_".$seed."_cDNA_unhit --max ".$directory."$seqFileName"."_".$seed."_cDNA_max";
    $full_command = $mapper_loc." ".$command." ".$ref_loc."".$IndexCDNA." ".$fasta_norrna." > ".$directory."$seqFileName"."_".$seed."_cDNA_mapped";
    #print "     $full_command\n";
    # Run
    system($full_command);
    # Print
    print "   Finished cDNA mapping $seqFileName"." with seedlength ".$seed."\n";
    # Process statistics
    system("wc ".$directory."$seqFileName"."_".$seed."_cDNA_hit  >> ".$stat_file);
    system("wc ".$directory."$seqFileName"."_".$seed."_cDNA_unhit >> ".$stat_file);
    
    my $fasta_nocDNA = $directory."$seqFileName"."_".$seed."_cDNA_unhit";
    
    ###### Map against genomic
    # Check genome Index
    #check_Bowtie_index($IndexGenome,$mapper);
    # Build command
    print "     Mapping against genomic $seqFileName"."\n";
    $command = "-l ".$seed." -n ".$mismatch." -p ".$cores." -m 1 --phred33-quals --quiet --al ".$directory."$seqFileName"."_".$seed."_genomic_hit --un ".$directory."$seqFileName"."_".$seed."_genomic_unhit";
    $full_command = $mapper_loc." ".$command." ".$ref_loc."".$IndexGenome." ".$fasta_nocDNA." > ".$directory."$seqFileName"."_".$seed."_genomic_mapped";
    #print "     $full_command\n";
    # Run
    system($full_command);
    # Print
    print "   Finished genomic mapping $seqFileName"." with seedlength ".$seed."\n";
    #Process statistics
    system("wc ".$directory."$seqFileName"."_".$seed."_genomic_hit >> ".$stat_file);
    system("wc ".$directory."$seqFileName"."_".$seed."_genomic_unhit >> ".$stat_file);
    
}

sub map_bowtie2 {
    
    # Catch
    my $seqFile = $_[0];
    my $seqFileName = $_[1];
    
    # Print
    print "   BOWTIE2 used for mapping----------------------------------\n";
    print "   Mapping $seqFileName"."\n";
    
    # Prepare
    my $directory = $work_dir."/".$mapper.$bowtie2Setting."/".$seqFileName.""."/";
    system "mkdir -p $directory";
    my ($fasta,$command,$full_command);
    
    ############################################################################
    #Map to rrna first, cDNA second (non-unique), afterwards to genomic (unique)
    ############################################################################
    
    # Get input fastq file
    #$fasta = $work_dir."/fastq/$seqFileName".".fastq";
    $fasta = $seqFile;
    
    my $fasta_to_rRNA;
    my $adapter = $adaptorSeq;
#    ###### Clip sequence
#    print "     Clipping $seqFileName"."\n";
#
#    my $clip_command = $fastx_clip_loc." -Q33 -a ".$adapter." -l 20 -c -n –v -i ".$work_dir."/fastq/$seqFileName".".fastq -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
#    print "     ".$clip_command."\n";
#    system ($clip_command);
    
    ######  Clip and Trim sequence
    if ($bowtie2Setting eq 'local') {
        print "     Bowtie2 local version is selected, no trimming/clipping performed, feed file to rRNA mapping\n"; #Bowtie local allows mismatches at beginning or end of read
        $fasta_to_rRNA = $fasta;
    } elsif ($bowtie2Setting eq 'end-to-end') {
        print "     Clipping $seqFileName".", Bowtie2 end-to-end version selected\n";
        my $clip_command = $fastx_clip_loc." -Q33 -a ".$adapter." -l 20 -c -n –v -i ".$work_dir."/fastq/$seqFileName".".fastq -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
        #print "     ".$clip_command."\n";
        system ($clip_command);
        print "     Trimming $seqFileName".", Bowtie2 end-to-end version selected\n";
        #print "     ".$fastx_trim_loc." -Q33 -f 2  –v -i ".$work_dir."/fastq/$seqFileName"."_clip.fastq -o ".$work_dir."/fastq/$seqFileName"."_trim.fastq\n";
        system ($fastx_trim_loc." -Q33 -f 2  –v -i ".$work_dir."/fastq/$seqFileName"."_clip.fastq -o ".$work_dir."/fastq/$seqFileName"."_trim.fastq");
        $fasta_to_rRNA = $work_dir."/fastq/$seqFileName"."_trim.fastq";
    }
    
    
    ###### Map against rRNA db
    # Check rRNA Index
    check_Bowtie_index($IndexrRNA,$mapper);
    # Build command
    print "     Mapping against rRNA $seqFileName"."\n";
    $ref_loc = get_ref_loc($mapper);
    $command = $mapper_loc." -p ".$cores." --".$bowtie2Setting." --sensitive-local --al ".$work_dir."/fastq/$seqFileName"."_rrna.fq --un ".$work_dir."/fastq/$seqFileName"."_norrna.fq  -x ".$ref_loc."".$IndexrRNA." -U ".$fasta_to_rRNA.">/dev/null";
    #print "     $command\n";
    # Run
    system($command);
    # Print
    print "   Finished rRNA multiseed alignment of $seqFileName"." with seedlength 20\n";
    # Process statistics
    system("wc ".$fasta_to_rRNA." >> ".$stat_file);
    system("wc ".$work_dir."/fastq/$seqFileName"."_rrna.fq >> ".$stat_file);
    system("wc ".$work_dir."/fastq/$seqFileName"."_norrna.fq >> ".$stat_file);
    
    my $fasta_norrna = $work_dir."/fastq/$seqFileName"."_norrna.fq";
    
    
    ###### Map against cDNA
    # Check cDNA Index
    check_Bowtie_index($IndexCDNA,$mapper);
    # Build command
    print "     Mapping against cDNA $seqFileName"."\n";
    $command = " -p ".$cores." --norc --".$bowtie2Setting." --phred33 --quiet --al ".$directory."$seqFileName"."_20_cDNA_hit --un ".$directory."$seqFileName"."_20_cDNA_unhit ";
    $full_command = $mapper_loc." ".$command." -x ".$ref_loc."".$IndexCDNA." -U ".$fasta_norrna." -S ".$directory."$seqFileName"."_20_cDNA_mapped";
    #print "     $full_command\n";
    # Run
    system($full_command);
    # Print
    print "   Finished cDNA mapping $seqFileName"." with seedlength 20"."\n";
    # Process statistics
    system("wc ".$directory."$seqFileName"."_20_cDNA_hit  >> ".$stat_file);
    system("wc ".$directory."$seqFileName"."_20_cDNA_unhit >> ".$stat_file);
    
    my $fasta_nocDNA = $directory."$seqFileName"."_20_cDNA_unhit";
    
    ###### Map against genomic
    # Check genome Index
    #check_Bowtie_index($IndexGenome,$mapper);
    # Build command
    print "     Mapping against genomic $seqFileName"."\n";
    $command = "-p ".$cores." --".$bowtie2Setting." --phred33 --quiet --al ".$directory."$seqFileName"."_20_genomic_hit --un ".$directory."$seqFileName"."_20_genomic_unhit";
    $full_command = $mapper_loc." ".$command." -x ".$ref_loc."".$IndexGenome." -U  ".$fasta_nocDNA." -S ".$directory."$seqFileName"."_20_genomic_mapped";
    #print "     $full_command\n";
    # Run
    system($full_command);
    # Print
    print "   Finished genomic mapping $seqFileName"." with seedlength 20"."\n";
    #Process statistics
    system("wc ".$directory."$seqFileName"."_20_genomic_hit >> ".$stat_file);
    system("wc ".$directory."$seqFileName"."_20_genomic_unhit >> ".$stat_file);
    
}

sub map_STAR_ribo {
    
    # Catch
    my $seqFiles = $_[0];
    my $seqFileName = $_[1];
    my @splitSeqFiles = split(/,/,$seqFiles);
    my $seqFile  = $splitSeqFiles[0];
    my $seqFile2 = $splitSeqFiles[1];
    
    my ($fasta,$fasta1,$fasta2,$fasta_norrna,$command,$full_command);
    my $ref_loc = get_ref_loc($mapper);
    # Check if main STAR index folder exists
    if (!-d $ref_loc) { system("mkdir -p ".$ref_loc); print "main STAR folder has been created\n";}
    
    # Print
    print "   STAR used for mapping----------------------------------\n";
    print "   Mapping $seqFileName"."\n";
    
    # Get input fastq file
    if ($readtype eq "ribo" || $readtype =~ m/SE/) {
        #$fasta = $work_dir."/fastq/$seqFileName".".fastq";
        $fasta = $seqFile;
    } elsif ($readtype =~ m/PE/) {
        $fasta1 = $seqFile;
        $fasta2 = $seqFile2;
        #$fasta1 = $work_dir."/fastq/$seqFileName".".1.fastq";
        #$fasta2 = $work_dir."/fastq/$seqFileName".".2.fastq";
    }
    
    # Prepare
    my $directory = $work_dir."/".$mapper."/".$seqFileName.""."/";
    system "mkdir -p $directory";

    
    # We need to first clip the adapter with fastx_clipper?
    my $clipfirst = "N";
    if ($clipfirst eq "Y") {
    
        print "     Clipping $seqFileName"." using fastx_clipper tool\n";
        # With length cut-off
        #my $clip_command = $fastx_clip_loc." -Q33 -a ".$adaptorSeq." -l 20 -c -n –v -i ".$fasta." -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
        # Without length cut-off and adaptor presence
        my $clip_command = $fastx_clip_loc." -Q33 -a ".$adaptorSeq." -l 20 -n –v -i ".$fasta." -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
        print "     ".$clip_command."\n";
        system ($clip_command);
        $fasta = $work_dir."/fastq/$seqFileName"."_clip.fastq";
        print "clipfasta= $fasta\n";
    }
    my $clip_stat = ($clipfirst eq "Y") ? " " : "--clip3pAdapterSeq ".$adaptorSeq." --clip3pAdapterMMp 0.1 ";

    
    
    #GO FOR STAR-pHIX mapping
    if ($phix eq "Y") {
        #Check if pHIX STAR index exists?
        check_STAR_index($IndexPhix);
        
        print "     Mapping against Phix $seqFileName"."\n";
        ###### Map against phix db using STAR
        
        
        # Build command
        system("mkdir  -p ".$work_dir."/fastq/nophix");
        #$command = $STAR_loc." --genomeLoad LoadAndKeep --outFilterMismatchNmax 2 --outFilterScoreMinOverLread .95 --outFilterMatchNminOverLread .95 --seedSearchStartLmaxOverLread .5 ".$clip_stat." --alignIntronMax 1 --genomeDir ".$ref_loc.$IndexPhix." --readFilesIn ".$fasta."  --outFileNamePrefix ".$work_dir."/fastq/nophix/ --runThreadN ".$cores." --outReadsUnmapped Fastx";
        $command = $STAR_loc." --genomeLoad LoadAndKeep --outFilterMismatchNmax 2  --seedSearchStartLmaxOverLread .5 ".$clip_stat." --alignIntronMax 1 --genomeDir ".$ref_loc.$IndexPhix." --readFilesIn ".$fasta."  --outFileNamePrefix ".$work_dir."/fastq/nophix/ --runThreadN ".$cores." --outReadsUnmapped Fastx";
        #print "     $command\n";
        # Run
        system($command);
        # Print
        print "   Finished rRNA multiseed mapping $seqFileName"."\n";
        # Process statistics
        open (STATS, ">>".$stat_file);
        my ($inReads, $mappedReadsU,$mappedReadsM, $unmappedReads) = parseLogSTAR($work_dir."/fastq/nophix/");
        my $mappedReads = $mappedReadsU + $mappedReadsM;
        print STATS "STAR ".$run_name." ".$seqFileName." "."fastq phix ".$inReads."\n";
        print STATS "STAR ".$run_name." ".$seqFileName." "."hit phix ".$mappedReads."\n";
        print STATS "STAR ".$run_name." ".$seqFileName." "."unhit phix ".$unmappedReads."\n";
        close(STATS);
        
        # Rename unmapped.out.mate1 for further analysis
        system("mv ".$work_dir."/fastq/nophix/Unmapped.out.mate1 ".$work_dir."/fastq/".$seqFileName."_nophix.fq"); #For further processing against genomic!!
        $fasta = $work_dir."/fastq/".$seqFileName."_nophix.fq";
        

    }
    
    # If RIBO-SEQ prior rRNA mapping is necessary
    if ($readtype eq "ribo") {
        #GO FOR STAR-rRNA mapping
        if ($prev_mapper eq 'STAR') {
            
            #Check if rRNA STAR index exists?
            check_STAR_index($IndexrRNA);
            
            print "     Mapping against rRNA $seqFileName"."\n";
            ###### Map against rRNA db using STAR (includes adapter clipping or exluding adapter clipping, dependent on previous clipping process)
            
            $ref_loc = get_ref_loc($prev_mapper);
            # Build command
            #$command = $STAR_loc." --genomeLoad LoadAndKeep --outFilterScoreMinOverLread .95 --outFilterMatchNminOverLread .95 --seedSearchStartLmaxOverLread .5 ".$clip_stat." --genomeDir ".$ref_loc.$IndexrRNA." --readFilesIn ".$fasta." --outFilterMismatchNmax 2 --outFileNamePrefix ".$work_dir."/fastq/ --runThreadN ".$cores." --outReadsUnmapped Fastx";
            $command = $STAR_loc." --genomeLoad LoadAndKeep --seedSearchStartLmaxOverLread .5 ".$clip_stat." --genomeDir ".$ref_loc.$IndexrRNA." --readFilesIn ".$fasta." --outFilterMismatchNmax 2 --outFileNamePrefix ".$work_dir."/fastq/ --runThreadN ".$cores." --outReadsUnmapped Fastx";
            
            #print "     $command\n";
            # Run
            system($command);
            # Print
            print "   Finished rRNA multiseed mapping $seqFileName"."\n";
            # Process statistics
            open (STATS, ">>".$stat_file);
            my ($inReads, $mappedReadsU,$mappedReadsM, $unmappedReads) = parseLogSTAR($work_dir."/fastq/");
            my $mappedReads = $mappedReadsU + $mappedReadsM;
            print STATS "STAR ".$run_name." ".$seqFileName." "."fastq rRNA ".$inReads."\n";
            print STATS "STAR ".$run_name." ".$seqFileName." "."hit rRNA ".$mappedReads."\n";
            print STATS "STAR ".$run_name." ".$seqFileName." "."unhit rRNA ".$unmappedReads."\n";
            close(STATS);
            
            # Rename unmapped.out.mate1 for further analysis
            system("mv ".$work_dir."/fastq/Unmapped.out.mate1 ".$work_dir."/fastq/".$seqFileName."_norrna.fq"); #For further processing against genomic!!
            
        }
        #GO FOR CLIP-TRIM-BOWTIE to get clipped, trimmed, norRNA reads
        elsif ($prev_mapper eq 'Bowtie') {
            ###### Clip and Trim sequence
            print "     Clipping $seqFileName"."\n";
            
            my $adapter = $adaptorSeq;
            my $clip_command = $fastx_clip_loc." -Q33 -a ".$adapter." -l 20 -c -n –v -i ".$work_dir."/fastq/$seqFileName".".fastq -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
            #print "     ".$clip_command."\n";
            system ($clip_command);
            print "     Trimming $seqFileName"."\n";
            #print "     ".$fastx_trim_loc." -Q33 -f 2  –v -i ".$work_dir."/fastq/$seqFileName"."_clip.fastq -o ".$work_dir."/fastq/$seqFileName"."_trim.fastq\n";
            system ($fastx_trim_loc." -Q33 -f 2  –v -i ".$work_dir."/fastq/$seqFileName"."_clip.fastq -o ".$work_dir."/fastq/$seqFileName"."_trim.fastq");
            
            ###### Map against rRNA db using Bowtie
            # Check rRNA Index
            check_Bowtie_index($IndexrRNA,$prev_mapper);
            # Build command
            print "     Mapping against rRNA $seqFileName"."\n";
            $ref_loc = get_ref_loc($prev_mapper);
            $command = $bowtie_loc." -p ".$cores." --sam --seedlen 23 --al ".$work_dir."/fastq/$seqFileName"."_rrna.fq --un ".$work_dir."/fastq/$seqFileName"."_norrna.fq ".$ref_loc."".$IndexrRNA." ".$work_dir."/fastq/$seqFileName"."_trim.fastq>/dev/null";
            #print "     $command\n";
            # Run
            system($command);
            # Print
            print "   Finished rRNA mapping $seqFileName"." with seedlength 23\n";
            # Process statistics
            system("wc ".$work_dir."/fastq/$seqFileName"."_trim.fastq >> ".$stat_file);
            system("wc ".$work_dir."/fastq/$seqFileName"."_rrna.fq >> ".$stat_file);
            system("wc ".$work_dir."/fastq/$seqFileName"."_norrna.fq >> ".$stat_file);
            
        }
        # GO FOR BOWTIE2_LOCAL_VERY-FAST to get unclipped/untrimmed norRNA reads
        elsif ($prev_mapper eq 'Bowtie2') {
            ######  Clip and Trim sequence
            #print "     Clipping $seqFileName"."\n";
            
            #my $adapter = $adaptorSeq;
            #my $clip_command = $fastx_clip_loc." -Q33 -a ".$adapter." -l 20 -c -n –v -i ".$work_dir."/fastq/$seqFileName".".fastq -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
            #print "     ".$clip_command."\n";
            #system ($clip_command);
            print "     Bowtie2 local version is selected, no trimming performed, feed clipped file to rRNA mapping\n"; #Bowtie local allows mismatches at beginning or end of read
            
            # Use input fasta
            #my $fasta_to_rRNA = $fasta;
            # Use clipped fasta
            #my $fasta_to_rRNA = $work_dir."/fastq/$seqFileName"."_clip.fastq";
            
            ###### Map against rRNA db
            # Check rRNA Index
            check_Bowtie_index($IndexrRNA,$prev_mapper);
            # Build command
            $ref_loc = get_ref_loc($prev_mapper);
            print "     Mapping against rRNA $seqFileName"."\n";
            $command = $bowtie2_loc." -p ".$cores." --".$bowtie2Setting." --sensitive-local --al ".$work_dir."/fastq/$seqFileName"."_rrna.fq --un ".$work_dir."/fastq/$seqFileName"."_norrna.fq  -x ".$ref_loc."".$IndexrRNA." -U ".$fasta.">/dev/null";
            #print "     $command\n";
            # Run
            system($command);
            # Print
            print "   Finished rRNA multiseed alignment of $seqFileName"." with seedlength 20\n";
            # Process statistics
            system("wc ".$fasta." >> statistics.txt");
            system("wc ".$work_dir."/fastq/$seqFileName"."_rrna.fq >> ".$stat_file);
            system("wc ".$work_dir."/fastq/$seqFileName"."_norrna.fq >> ".$stat_file);
            
        }
        
        $fasta_norrna = $work_dir."/fastq/$seqFileName"."_norrna.fq";
    }

    # Check genomic STAR index
    # If it doesn't exist, it's created from data within the iGenome directory
    check_STAR_index($STARIndexGenomeFolder);
    
    # Map vs genomic
    print "     Mapping against genomic $seqFileName"."\n";
    
    # alignment dependent on read type
    if ($readtype eq "ribo") {
    $ref_loc = get_ref_loc($mapper);
        #--seedSearchStartLmaxOverLread 0.5 --outFilterScoreMinOverLread .75 --outFilterMatchNminOverLread .75
    $command = $STAR_loc." --outSAMattributes All --genomeLoad NoSharedMemory ".$clip_stat." --seedSearchStartLmaxOverLread .5 --outFilterMultimapNmax 16 --genomeDir ".$ref_loc.$STARIndexGenomeFolder." --readFilesIn ".$fasta_norrna." --runThreadN ".$cores." --outFilterMismatchNmax 2 -- outFileNamePrefix ".$directory;
    } elsif ($readtype eq "PE_polyA") {
    $command = $STAR_loc." --outSAMattributes All --genomeLoad NoSharedMemory --chimSegmentMin 15 --chimJunctionOverhangMin 15 --outFilterIntronMotifs RemoveNoncanonicalUnannotated --outSAMunmapped Within --outReadsUnmapped Fastx --seedSearchStartLmaxOverLread 0.5 --outFilterMultimapNmax 16 --outFilterMismatchNmax 6 --genomeDir ".$ref_loc.$STARIndexGenomeFolder." --readFilesIn ".$fasta1." ".$fasta2." --runThreadN ".$cores." --outFilterType BySJout -- outFileNamePrefix ".$directory;
    }
    
    print "     ".$command."\n";
    system($command);
    systemError("STAR",$?,$!);
    # convert SAM output file to BAM file
    print "converting SAM output to BAM...\n";
    system($samtools_loc." view -bS -o ".$directory."Aligned.out.bam ".$directory."Aligned.out.sam > /dev/null 2>&1");
    systemError("Samtools view",$?,$!);
    # sort the BAM file
    print "sorting STAR hits...\n";
    system($samtools_loc." sort -@ ". $cores. " -m 1000M ".$directory."Aligned.out.bam ".$directory."Aligned.sorted 2>&1" );
    systemError("Samtools sort",$?,$!);
    #  convert BAM back to SAM file
    print "converting BAM back to SAM...\n";
    system($samtools_loc." view -h -o ".$directory."Aligned.sorted.sam ".$directory."Aligned.sorted.bam > /dev/null 2>&1");
    systemError("Samtools view",$?,$!);
    
    # rename SAM output file
        print "renaming SAM output file...\n";
    
    # Bam file depends on what fastq file is processed (fastq1 = untreated, fastq2 = treaeted; that is for RIBO-seq experiments)
    my $bamf = ($seqFileName  eq 'fastq1') ? $out_sam_untr : $out_sam_tr;
    system("mv ".$directory."Aligned.sorted.sam ".$bamf);

    
    # Process statistics
    open (STATS, ">>".$stat_file);
    my ($inReads,$mappedReadsU,$mappedReadsM, $unmappedReads) = parseLogSTAR($work_dir."/".$mapper."/".$seqFileName."/");
    print STATS "STAR ".$run_name." ".$seqFileName." "."fastq genomic ".$inReads."\n";
    print STATS "STAR ".$run_name." ".$seqFileName ." "."hitU genomic ".$mappedReadsU."\n";
    print STATS "STAR ".$run_name." ".$seqFileName ." "."hitM genomic ".$mappedReadsM."\n";
    print STATS "STAR ".$run_name." ".$seqFileName." "."unhit genomic ".$unmappedReads."\n";
    close(STATS);
    
}

sub check_STAR_index {
    
    # Catch
    my $starIndexDir = $_[0];
    
    $ref_loc = get_ref_loc($mapper);
    my $starIndexDirComplete = $ref_loc.$starIndexDir;
    
    #print "$starIndexDirComplete\n";
    print "     ----checking for STAR index folder...\n";
    if (!-d $starIndexDirComplete){
        if ($starIndexDir =~ /rRNA/) {
            print "no STAR directory". $starIndexDir ."found\ncreating STAR index without annotation ...\n";
            system("mkdir -p ".$starIndexDirComplete);
            
            #Get rRNA fasta and from iGenome folder (rRNA sequence are located in /Sequence/AbundantSequences folder)
            #GenomeSAIndexNbases needs to be adapted because small "rRNA-genome" size +/- 8000bp. => [GenomeSAIndexNbases = log2(size)/2 - 1]
            my $PATH_TO_FASTA = $rRNA_fasta;
            #print $STAR_loc." --runMode genomeGenerate --genomeSAindexNbases 6  --genomeDir ".$starIndexDirComplete." --runThreadN ". $cores." --genomeFastaFiles ".$PATH_TO_FASTA."\n";
            system($STAR_loc." --runMode genomeGenerate --genomeSAindexNbases 6  --genomeDir ".$starIndexDirComplete." --runThreadN ". $cores." --genomeFastaFiles ".$PATH_TO_FASTA);
            systemError("STAR genome",$?,$!);
            #print "done!\n\n";
                        
        }
        elsif ($starIndexDir =~ /phix/) {
            print "no STAR directory". $starIndexDir ."found\ncreating STAR index without annotation ...\n";
            system("mkdir -p ".$starIndexDirComplete);
            
            #Get phix fasta and from iGenome folder (phix sequence(s) are located in /Sequence/AbundantSequences folder)
            #GenomeSAIndexNbases needs to be adapted because small "rRNA-genome" size +/- 8000bp. => [GenomeSAIndexNbases = log2(size)/2 - 1]
            my $PATH_TO_FASTA = $phix_fasta;
            #print $STAR_loc." --runMode genomeGenerate --genomeSAindexNbases 6  --genomeDir ".$starIndexDirComplete." --runThreadN ". $cores." --genomeFastaFiles ".$PATH_TO_FASTA."\n";
            system($STAR_loc." --runMode genomeGenerate --genomeSAindexNbases 6  --genomeDir ".$starIndexDirComplete." --runThreadN ". $cores." --genomeFastaFiles ".$PATH_TO_FASTA);
            systemError("STAR genome",$?,$!);
            #print "done!\n\n";
            
        }
        elsif ($starIndexDir =~ /genome/) {
            print "no STAR ".$spec." genome directory found\ncreating STAR index with annotation ...\n";
            system("mkdir -p ".$starIndexDirComplete);
            
            #Get Genome fasta and GTF file from iGenome folder (genome sequence is located in /Sequence/WholeGenomeFasta folder)
            my $PATH_TO_FASTA = $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Sequence/WholeGenomeFasta/genome.fa";
            my $PATH_TO_GTF   = $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Annotation/Genes/genes.gtf";
            #print $STAR_loc." --runMode genomeGenerate --sjdbOverhang ".$readlengthMinus." --genomeDir ".$starIndexDirComplete." --genomeFastaFiles ".$PATH_TO_FASTA." --sjdbGTFfile ".$PATH_TO_GTF." --runThreadN ".$cores. "\n";
            system($STAR_loc." --runMode genomeGenerate --sjdbOverhang ".$readlengthMinus." --genomeDir ".$starIndexDirComplete." --genomeFastaFiles ".$PATH_TO_FASTA." --sjdbGTFfile ".$PATH_TO_GTF." --runThreadN ".$cores);
            systemError("STAR genome",$?,$!);
            #print "done!\n\n";
        }
    }
    
}

sub check_Bowtie_index {
    
    # Catch
    my $bowtieIndex = $_[0];
    my $mapper      = $_[1];
    
    # Set
    $ref_loc = get_ref_loc($mapper);
    my $bowtieIndexFile = $ref_loc.$bowtieIndex;
    my $bowtieIndexFileCheck = ($mapper eq "Bowtie1") ? $ref_loc.$bowtieIndex.".1.ebwt" : $ref_loc.$bowtieIndex.".1.bt2";
    my $bowtieloc = ($mapper eq "Bowtie1") ? $bowtie_loc : $bowtie2_loc;
    
    # Check if index exists
    print "     ----checking for Bowtie index file...\n";
    print "         $bowtieIndexFileCheck\n";
    if (-e $bowtieIndexFileCheck){
        print "     ----ok, file found\n\n";
    } else {
        if ($bowtieIndex =~ /rRNA/) {
            print "no Bowtie ". $bowtieIndexFile ." found\ncreating bowtie index ...\n";
            
            #Get rRNA fasta and from iGenome folder (rRNA sequence are located in /Sequence/AbundantSequences folder)
            my $PATH_TO_FASTA = $rRNA_fasta;
            print $bowtieloc."-build ".$PATH_TO_FASTA." ".$bowtieIndexFile."\n";
            system($bowtieloc."-build ".$PATH_TO_FASTA." ".$bowtieIndexFile);
            systemError("Bowtie index creation error",$?,$!);
            print "done!\n\n";
            
        }
        elsif ($bowtieIndex =~ /phix/) {
            print "no Bowtie ". $bowtieIndexFile ."found\ncreating bowtie index ...\n";
            
            #Get phix fasta and from iGenome folder (phix sequence(s) are located in /Sequence/AbundantSequences folder)
            my $PATH_TO_FASTA = $phix_fasta;
            print $bowtieloc."-build ".$PATH_TO_FASTA." ".$bowtieIndexFile."\n";
            system($bowtieloc."-build ".$PATH_TO_FASTA." ".$bowtieIndexFile);
            systemError("Bowtie index creation error",$?,$!);
            print "done!\n\n";
            
        }
        elsif ($bowtieIndex =~ /cdna/) {
            print "no Bowtie ". $bowtieIndexFile ."found\ncreating bowtie index ...\n";
            
            #Get phix fasta and from iGenome folder (phix sequence(s) are located in /Sequence/AbundantSequences folder)
            my $PATH_TO_FASTA = $cDNA_fasta;
            print $bowtieloc."-build ".$PATH_TO_FASTA." ".$bowtieIndexFile."\n";
            system($bowtieloc."-build ".$PATH_TO_FASTA." ".$bowtieIndexFile);
            systemError("Bowtie index creation error",$?,$!);
            print "done!\n\n";
            
        }
    }
    
}

sub map_topHat2_ribo {
    
    # Catch
    my $seqFiles = $_[0];
    my $seqFileName = $_[1];
    my @splitSeqFiles = split(/,/,$seqFiles);
    my $seqFile  = $splitSeqFiles[0];
    my $seqFile2 = $splitSeqFiles[1];
    $ref_loc = get_ref_loc($mapper);
    
    #print "$seqFiles, $seqFileName\n"; exit;
    # Prepare
    my $directory = $work_dir."/".$mapper."/".$seqFileName."/";
    system "mkdir -p $directory";
    
    my ($fasta,$fasta2,$command,$full_command);
    
    # Get input fastq file
    #$fasta = $work_dir."/fastq/$seqFileName".".fastq";
    $fasta = $seqFile;
    $fasta2 = $seqFile2;
    
    # GO FOR CLIP-TRIM-BOWTIE to get clipped, trimmed, norRNA reads
    if ($prev_mapper eq 'Bowtie') {
        ###### Clip and Trim sequence
        print "     Clipping $seqFileName"."\n";
        my $adapter = $adaptorSeq;
        my $clip_command = $fastx_clip_loc." -Q33 -a ".$adapter." -l 20 -c -n –v -i ".$work_dir."/".$fasta." -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
        print "     ".$clip_command."\n";
        system ($clip_command);
        print "     Trimming $seqFileName"."\n";
        print "     ".$fastx_trim_loc." -Q33 -f 2  –v -i ".$work_dir."/fastq/$seqFileName"."_clip.fastq -o ".$work_dir."/fastq/$seqFileName"."_trim.fastq\n";
        system ($fastx_trim_loc." -Q33 -f 2  –v -i ".$work_dir."/fastq/$seqFileName"."_clip.fastq -o ".$work_dir."/fastq/$seqFileName"."_trim.fastq");
        
        ###### Map against rRNA db using Bowtie
        # Check rRNA Index
        check_Bowtie_index($IndexrRNA,$prev_mapper);
        # Build command
        $ref_loc = get_ref_loc($prev_mapper);
        print "     Mapping against rRNA $seqFileName"."\n";
        $command = $bowtie_loc." -p ".$cores." --sam --seedlen 23 --al ".$work_dir."/fastq/$seqFileName"."_rrna.fq --un ".$work_dir."/fastq/$seqFileName"."_norrna.fq ".$ref_loc."".$IndexrRNA." ".$work_dir."/fastq/$seqFileName"."_trim.fastq>/dev/null";
        print "     $command\n";
        # Run
        system($command);
        # Print
        print "   Finished rRNA mapping $seqFileName"." with seedlength 23\n";
        # Process statistics
        system("wc ".$work_dir."/fastq/$seqFileName"."_trim.fastq >> ".$stat_file);
        system("wc ".$work_dir."/fastq/$seqFileName"."_rrna.fq >> ".$stat_file);
        system("wc ".$work_dir."/fastq/$seqFileName"."_norrna.fq >> ".$stat_file);
        
    }
    # GO FOR BOWTIE2_LOCAL_VERY-FAST to get untrimmed norRNA reads
    elsif ($prev_mapper eq 'Bowtie2') {
        
        ######  Clip and Trim sequence
        print "     Clipping $seqFileName"."\n";
        
        my $adapter = $adaptorSeq;
        #my $clip_command = $fastx_clip_loc." -Q33 -a ".$adapter." -l 20 -c -n –v -i ".$work_dir."/".$fasta." -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
        my $clip_command = $fastx_clip_loc." -Q33 -a ".$adapter." -n –v -i ".$work_dir."/".$fasta." -o ".$work_dir."/fastq/$seqFileName"."_clip.fastq";
        print "     ".$clip_command."\n";
        system ($clip_command);
        print "     Bowtie2 local version is selected, no trimming performed, feed clipped file to rRNA mapping\n"; #Bowtie local allows mismatches at beginning or end of read
        
        # Use input fasta
        #my $fasta_to_rRNA = $fasta;
        # Use clipped fasta
        my $fasta_to_phix = $work_dir."/fastq/$seqFileName"."_clip.fastq";
        
        #GO FOR pHIX mapping
        if ($phix eq "Y") {
            #Check if pHIX STAR index exists?
            check_Bowtie_index($IndexPhix,$prev_mapper);
            
            print "     Mapping against Phix $seqFileName"."\n";
            ###### Map against phix db using Bowtie2
            
            # Build command
            system("mkdir  -p ".$work_dir."/fastq/nophix");
            $command = $bowtie2_loc." -p ".$cores." --".$bowtie2Setting." --sensitive-local --al ".$work_dir."/fastq/$seqFileName"."_phix.fq --un ".$work_dir."/fastq/$seqFileName"."_nophix.fq  -x ".$ref_loc."".$IndexPhix." -U ".$fasta_to_phix.">/dev/null";
            print "     $command\n";
            # Run
            system($command);
            # Print
            print "   Finished phix multiseed mapping $seqFileName"."\n";
            
        }
        
        my $fasta_to_rRNA = $work_dir."/fastq/$seqFileName"."_nophix.fq";
        
        ###### Map against rRNA db
        # Check rRNA Index
        check_Bowtie_index($IndexrRNA,$prev_mapper);
        # Build command
        $ref_loc = get_ref_loc($prev_mapper);
        print "     Mapping against rRNA $seqFileName"."\n";        
        $command = $bowtie2_loc." -p ".$cores." --".$bowtie2Setting." --sensitive-local --al ".$work_dir."/fastq/$seqFileName"."_rrna.fq --un ".$work_dir."/fastq/$seqFileName"."_norrna.fq  -x ".$ref_loc."".$IndexrRNA." -U ".$fasta_to_rRNA.">/dev/null";
        print "     $command\n";
        # Run
        system($command);
        # Print
        print "   Finished rRNA multiseed alignment of $seqFileName"." with seedlength 20\n";
        # Process statistics
        #system("wc ".$fasta_to_rRNA." >> statistics.txt");
        #system("wc ".$work_dir."/fastq/$seqFileName"."_rrna.fq >> ".$stat_file);
        #system("wc ".$work_dir."/fastq/$seqFileName"."_norrna.fq >> ".$stat_file);
        
    }
    
    my $fasta_norrna = $work_dir."/fastq/$seqFileName"."_norrna.fq";
    #my $fasta_norrna = $work_dir."/fastq/$seqFileName".".fastq";
    
    # Run TopHat2
    $ref_loc = get_ref_loc($mapper);
    my $PATH_TO_GTF   = $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Annotation/Genes/genes.gtf";
    my $PATH_TO_GENOME_INDEX = $ref_loc."".$IndexGenome;
    print $tophat2_loc." --max-multihits 16 --report-secondary-alignments  --coverage-search --segment-length 15 --no-convert-bam --output-dir ".$directory." -p ".$cores." --GTF ".$PATH_TO_GTF." ". $PATH_TO_GENOME_INDEX ." ". $fasta_norrna."\n";
    system($tophat2_loc." --max-multihits 16 --report-secondary-alignments  --coverage-search --segment-length 15 --no-convert-bam --output-dir ".$directory." -p ".$cores." --GTF ".$PATH_TO_GTF." ". $PATH_TO_GENOME_INDEX ." ". $fasta_norrna);
    
    
    open (STATS, ">>".$stat_file);
    my ($inReads,$mappedReadsU,$mappedReadsM, $unmappedReads) = parseLogTopHat($seqFileName);
    print STATS "TopHat2 ".$run_name." ".$seqFileName." "."fastq genomic ".$inReads."\n";
    print STATS "TopHat2 ".$run_name." ".$seqFileName." "."hitU genomic ".$mappedReadsU."\n";
    print STATS "TopHat2 ".$run_name." ".$seqFileName." "."hitM genomic ".$mappedReadsM."\n";
    print STATS "TopHat2 ".$run_name." ".$seqFileName." "."unhit genomic ".$unmappedReads."\n";
    close(STATS);
    
    # rename SAM output file
    print "renaming SAM output file...\n";
    
    # Bam file depends on what fastq file is processed (fastq1 = untreated, fastq2 = treaeted; that is for RIBO-seq experiments)
    my $bamf = ($seqFileName  eq 'fastq1') ? $out_sam_untr : $out_sam_tr;
    system("mv ".$directory."accepted_hits.sam ".$bamf);
    
    #Convert bam to sam
    #system($samtools_loc." view -h -o ".$directory."accepted_hits.sam ".$directory."accepted_hits.bam");
    
    #Extract perfect-match alignments from TopHat output.
    #samtools view -h XXX_vs_genome/accepted_hits.bam| grep -E '(NM:i:0)|(^@)'| samtools view –S –b ->XXX_vs_genome.bam
}

sub store_statistics {
    
    # DBH
    my ($file,$dsn,$us,$pw) = @_;
    my $dbh_sqlite_results = dbh($dsn,$us,$pw);
    
    
    ###############
    ## STATISTICS
    ##
    
    # Print
    print "Processing statistics!\n";
    
    # Gather statistics
    open (IN,"<".$stat_file) || die "ERROR";
    
    my $stat; my $ref; my $size; my $total;
    $total = "";
    
    #        131879368  164849210 3564964754 /data/RIBO_runs/RIBO_BioBix_Pipeline/fastq/lane2_trim.fastq
    #        32283460  40354325 870002442 /data/RIBO_runs/RIBO_BioBix_Pipeline/fastq/lane2_rrna.fq
    #        99595908  124494885 2694962312 /data/RIBO_runs/RIBO_BioBix_Pipeline/fastq/lane2_norrna.fq
    #        74699244   93374055 2039253175 /data/RIBO_runs/RIBO_BioBix_Pipeline/Bowtie2/lane2/lane2_20_cDNA_hit
    #        24896664  31120830 655709137 /data/RIBO_runs/RIBO_BioBix_Pipeline/Bowtie2/lane2/lane2_20_cDNA_unhit
    #        16721676  20902095 439928794 /data/RIBO_runs/RIBO_BioBix_Pipeline/Bowtie2/lane2/lane2_20_genomic_hit
    #        8174988  10218735 215780343 /data/RIBO_runs/RIBO_BioBix_Pipeline/Bowtie2/lane2/lane2_20_genomic_unhit
    
    
    
    while(my $line = <IN>){
        $line =~ s/^\s+//;
        my @a = split(/\s+/,$line);
        
        if ($line =~ m/^STAR/ ||  $line =~ m/^TopHat2/) {
            my $run_name = $a[1];
            my $lane = $a[2];
            my $ref = $a[4];#($line =~ m/(hit|unhit) genomic/) ? "genomic" : "rRNA";
            my $type = $a[3];
            $stat->{$run_name.".".$lane}->{$ref}->{$type} = ($a[5]);
            #print "$type,$a[5],$ref,$run_name,$lane\n";
        }
        else {
            
            # Check type processing for after against genomic run (name contains both _unhit and
            
            # Get some params
            $a[3] =~ /(fastq|norrna\.fq|rrna\.fq|hit|unhit)$/;
            my $type = ($1 eq "norrna.fq") ? "unhit" : ($1 eq "rrna.fq") ? "hit" : $1;
            
            # Get ref
            if ($a[3] =~ /\/fastq\//) { $ref = "rRNA";}
            elsif ($a[3] =~ /_(\d*)_(cDNA_hit|cDNA_unhit)/) { $ref = "cDNA"; }
            elsif ($a[3] =~ /_(\d*)_(genomic_hit|genomic_unhit)/) { $ref = "genomic";}
            
            # Get lane number
            $a[3] =~ /$fastqName(\d)/;
            my $lane = $1;
            
            # Fill hashref
            $stat->{$run_name."-".$lane}->{$ref}->{$type} = ($a[0] / 4);
            #print "$type,$a[0],$ref,$run_name,$lane\n";
        }
        
    }
    
    close(IN);
    #print Dumper ($stat);
    
    my $query_table = "CREATE TABLE IF NOT EXISTS `statistics` (
    `sample` varchar(200) default NULL,
    `type` varchar(200) default NULL,
    `total` int(11) default NULL,
    `mapped_U` int(11) default NULL,
    `mapped_M` int(11) default NULL,
    `mapped_T` int(11) default NULL,
    `unmapped` int(11) default NULL,
    `map_freq_U` decimal(10,5) default NULL,
    `map_freq_M` decimal(10,5) default NULL,
    `map_freq_T` decimal(10,5) default NULL    
    )";
    
    $dbh_sqlite_results->do($query_table);
    
    foreach my $sample (keys %$stat){
        
        # Calculate hit count for the STAR mapper (=unhit_count_rRNA minus unhit_count_genomic), only unhit fastq can be outputted by STAR command
        #if ($mapper eq 'STAR') {
        #    #Parse Log file of STAR alignment
        #    my ($mappedReads, $unmappedReads) = parseLogSTAR($seqFileName);
        #    $stat->{$sample}->{'genomic'}->{"hit"}   =   $mappedReads;
        #    $stat->{$sample}->{'genomic'}->{"unhit"} = $unmappedReads;
        #}
        
        my $prev_ref;
        foreach my $ref (keys %{$stat->{$sample}}) {
            # Dependant on mapper the order of reference sequences databases are rRNA-(cDNA-)genomic
            if ($mapper =~ /Bowtie/) {
                $prev_ref = ($ref eq "cDNA") ? "rRNA" : ($ref eq "genomic") ? "cDNA" : "";
            }
            elsif ($mapper eq 'STAR' || $mapper eq 'TopHat2') {
                if ($readtype eq 'ribo') {
                    $prev_ref = ($ref eq "genomic") ? "rRNA" : "";
                    $total = ($ref eq "rRNA" || $ref eq "phix") ? $stat->{$sample}->{$ref}->{"fastq"} : $stat->{$sample}->{$prev_ref}->{"unhit"};

                } elsif ($readtype =~ m/polyA/) {
                    $prev_ref = "";
                    $total = ($ref eq "genomic") ? $stat->{$sample}->{$ref}->{"fastq"} : "";
                }
            }
            
            my $query;

            
            if (($mapper eq "STAR" || $mapper eq "TopHat2") && $ref eq "genomic" ) {

                my $freq_U =  $stat->{$sample}->{$ref}->{"hitU"} / $stat->{$sample}->{$ref}->{"fastq"};
                my $freq_M =  $stat->{$sample}->{$ref}->{"hitM"} / $stat->{$sample}->{$ref}->{"fastq"};
                my $freq_T = $freq_U + $freq_M;
                my $map_T  = $stat->{$sample}->{$ref}->{"hitM"} + $stat->{$sample}->{$ref}->{"hitU"};
  
                $query = "INSERT INTO statistics (sample,type,total,mapped_U,mapped_M,mapped_T,unmapped,map_freq_U,map_freq_M,map_freq_T) VALUES (\'".$sample."\',\'".$ref."\',\'".$total."\',\'".$stat->{$sample}->{$ref}->{"hitU"}."\',\'".$stat->{$sample}->{$ref}->{"hitM"}."\',\'".$map_T."\',\'".$stat->{$sample}->{$ref}->{"unhit"}."\',\'".$freq_U."\',\'".$freq_M."\',\'".$freq_T."\')";
                
            } else {
                
                my $freq =  ($prev_ref eq "")       ? $stat->{$sample}->{$ref}->{"hit"} / $stat->{$sample}->{$ref}->{"fastq"}
                :  ($prev_ref eq "rRNA")   ? $stat->{$sample}->{$ref}->{"hit"} / $stat->{$sample}->{$prev_ref}->{"unhit"}
                :  ($prev_ref eq "cDNA")   ? $stat->{$sample}->{$ref}->{"hit"} / $stat->{$sample}->{$prev_ref}->{"unhit"} : "";
                
                $query = "INSERT INTO statistics (sample,type,total,mapped_T,unmapped,map_freq_T) VALUES (\'".$sample."\',\'".$ref."\',\'".$total."\',\'".$stat->{$sample}->{$ref}->{"hit"}."\',\'".$stat->{$sample}->{$ref}->{"unhit"}."\',\'".$freq."\')";
            }
                
            $dbh_sqlite_results->do($query);
            
        }
    }
    
    system("rm ".$stat_file);
    
}

###  Store all input variables in an SQLite table
sub store_input_vars {

    # Catch
    my $dsn = $_[0];
    my $us = $_[1];
    my $pw =  $_[2];
    my $run_name = $_[3];
    my $ensembl_version = $_[4];
    my $species = $_[5];
    my $mapper = $_[6];
    my $unique = $_[7];
    my $adaptor= $_[8];
    my $readlength= $_[9];
    my $readtype= $_[10];
    my $IGENOMES_ROOT = $_[11];
    my $nr_of_cores = $_[12];
    
    my $dbh_sqlite_results = dbh($dsn,$us,$pw);
    
    my $query_table = "CREATE TABLE IF NOT EXISTS `arguments` (
    `variable` varchar(200) default NULL,
    `value` varchar(200) default NULL
    )";

    
    $dbh_sqlite_results->do($query_table);
    
    
    my $query = "INSERT INTO arguments (variable,value) VALUES (\'run_name\',\'".$run_name."\')";
    $dbh_sqlite_results->do($query);

    $query = "INSERT INTO arguments (variable,value) VALUES (\'ensembl_version\',\'".$ensembl_version."\')";
    $dbh_sqlite_results->do($query);
    
    $query = "INSERT INTO arguments (variable,value) VALUES (\'species\',\'".$species."\')";
    $dbh_sqlite_results->do($query);
    
    $query = "INSERT INTO arguments (variable,value) VALUES (\'mapper\',\'".$mapper."\')";
    $dbh_sqlite_results->do($query);
    
    $query = "INSERT INTO arguments (variable,value) VALUES (\'unique\',\'".$unique."\')";
    $dbh_sqlite_results->do($query);
    
    $query = "INSERT INTO arguments (variable,value) VALUES (\'adaptor\',\'".$adaptor."\')";
    $dbh_sqlite_results->do($query);

    $query = "INSERT INTO arguments (variable,value) VALUES (\'readlength\',\'".$readlength."\')";
    $dbh_sqlite_results->do($query);
    
    $query = "INSERT INTO arguments (variable,value) VALUES (\'readtype\',\'".$readtype."\')";
    $dbh_sqlite_results->do($query);
    
    $query = "INSERT INTO arguments (variable,value) VALUES (\'igenomes_root\',\'".$IGENOMES_ROOT."\')";
    $dbh_sqlite_results->do($query);
    
    $query = "INSERT INTO arguments (variable,value) VALUES (\'nr_of_cores\',\'".$nr_of_cores."\')";
    $dbh_sqlite_results->do($query);
}

### GET INDEX LOCATION ###
sub get_ref_loc {

    # Catch
    my $mapper  = $_[0];
    
    my $ref_loc = ($mapper eq "Bowtie1") ? $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Sequence/BowtieIndex/"                 #Bowtie indexes
    : ($mapper eq "Bowtie2" || $mapper eq "TopHat2") ? $IGENOMES_ROOT."/".$spec."/Ensembl/".$assembly."/Sequence/Bowtie2Index/"   #Bowtie2 indexes
    : $STAR_ref_loc; #STAR indexes
    
    return($ref_loc);
    
}

### DBH ###
sub dbh {
    
    # Catch
    my $db  = $_[0];
    my $us	= $_[1];
    my $pw	= $_[2];
    
    # Init DB
    my $dbh = DBI->connect($db,$us,$pw,{ RaiseError => 1 },) || die "Cannot connect: " . $DBI::errstr;
    
    return($dbh);
}

### SYSTEMERROR ###
sub systemError {
    my ($command,$returnValue,$errorMessage) = @_;
    if ($returnValue == -1){
        die "$command failed!\n$errorMessage\n\n";
    }
}

sub parseLogSTAR {
    
    # Catch
    my $dir  = $_[0];
    open (LOG,"<".$dir."Log.final.out") || die "ERROR";
    
    my ($line,@lineSplit,$inReads,$mappedReadsU,$mappedReadsM,$mappedReads,$unmappedReads);
    
    while($line = <LOG>) {
        @lineSplit = split(/\|/,$line);
        if ($lineSplit[0] =~ /Number of input reads/) {
            $lineSplit[1] =~s/^\s+//;
            $lineSplit[1] =~s/\s+$//;
            $inReads = $lineSplit[1];
        }
        if ($lineSplit[0] =~ /Uniquely mapped reads number/) {
            $lineSplit[1] =~s/^\s+//;
            $lineSplit[1] =~s/\s+$//;
            $mappedReadsU = $lineSplit[1];
        }
        if ($lineSplit[0] =~ /Number of reads mapped to multiple loci/) {
            $lineSplit[1] =~s/^\s+//;
            $lineSplit[1] =~s/\s+$//;
            $mappedReadsM = $lineSplit[1];
        }
    }
    $mappedReads = $mappedReadsU + $mappedReadsM;
    $unmappedReads = $inReads - $mappedReads;
    close(LOG);
    return ($inReads,$mappedReadsU,$mappedReadsM,$unmappedReads);
}

sub parseLogTopHat {
    
    # Catch
    my $seqFileName  = $_[0];
    my $directory = $work_dir."/".$mapper."/".$seqFileName."/";
    
    
    #Reads:
    #Input:  23548371
    #Mapped:  21346722 (90.7% of input)
    #    of these:   8486845 (39.8%) have multiple alignments (1459279 have >15)
    #    90.7% overall read alignment rate.
    
    open (LOG1,"<".$directory."align_summary.txt") || die "ERROR";
    
    my ($line,$inReads,$mappedReadsU,$mappedReadsM,$mappedReads,$unmappedReads,$mappedReadsMcorr);
    
    while($line = <LOG1>) {
        
        if ($line =~ /Input:  (\d+)/) {
            $inReads= $1;
        }
        if ($line =~ /Mapped:  (\d+)/) {
            $mappedReads= $1;
        }
        if ($line =~ /of these:\s+(\d+)\s+\(.*\((\d+)/) {
            $mappedReadsM= $1;
            $mappedReadsMcorr=$2;
        }
    }
    
    $mappedReadsU  = $mappedReads - $mappedReadsM;
    $mappedReadsM  = $mappedReadsM - $mappedReadsMcorr;
    $mappedReads   = $mappedReads - $mappedReadsMcorr;
    $unmappedReads = $inReads - $mappedReads;


    close(LOG1);
    
    return ($inReads,$mappedReadsU,$mappedReadsM,$unmappedReads);
    
#    open (LOG1,"<".$directory."bowtie.left_kept_reads.log") || die "ERROR";
#    open (LOG2,"<".$directory."bowtie.left_kept_reads.m2g_um.log") || die "ERROR";
#
#    my ($line,@lineSplit,$inReads,$mappedReadsU,$mappedReadsM,$mappedReads1U,$mappedReads1M,$mappedReads2U,$mappedReads2M,$mappedReads,$unmappedReads);
#    
#    while($line = <LOG1>) {
#        $line =~s/^\s+//;
#        $line =~s/\s+$//;
#        @lineSplit = split(/\s+/,$line);
#        if ($line =~ /aligned exactly 1 time/) {
#            $mappedReads1U = $lineSplit[0];
#        }
#        if ($line =~ /aligned >1 times/) {
#            $mappedReads1M = $lineSplit[0];
#        }
#        if ($line =~ /reads; of these:/) {
#            $inReads = $lineSplit[0];
#        }
#    }
#    
#    while($line = <LOG2>) {
#        $line =~s/^\s+//;
#        $line =~s/\s+$//;
#        @lineSplit = split(/\s+/,$line);
#        if ($line =~ /aligned exactly 1 time/) {
#            $mappedReads2U = $lineSplit[0];
#        }
#        if ($line =~ /aligned >1 times/) {
#            $mappedReads2M = $lineSplit[0];
#        }
#    }
#    
#    $mappedReadsU = $mappedReads1U + $mappedReads2U;
#    $mappedReadsM = $mappedReads1M + $mappedReads2M;
#    
#    $mappedReads = $mappedReads1U + $mappedReads1M + $mappedReads2U + $mappedReads2M;
#    $unmappedReads = $inReads - $mappedReads;
#    
#    close(LOG1);
#    close(LOG2);
    
    #return ($inReads,$mappedReadsU,$mappedReadsM,$unmappedReads);
}


sub RIBO_parse_store {
    
    # Catch
    my $seqFile = $_[0];
    my $seqFileName = $_[1];
    
    my $bedgr_s = ($seqFileName  eq 'fastq1') ? $out_bg_s_untr : $out_bg_s_tr;
    my $bedgr_as = ($seqFileName  eq 'fastq1') ? $out_bg_as_untr : $out_bg_as_tr;
    my $sam = ($seqFileName  eq 'fastq1') ? $out_sam_untr : $out_sam_tr;
    
    ## Get chromosome sizes and cDNA identifiers #############
    print "Getting chromosome sizes and cDNA to chromosome mappings ...\n";
    my %chr_sizes = %{get_chr_sizes($chromosome_sizes)};
    
    #Get SAM file dependent on choice of mapper
    # If sorted SAM (star)
    #my $sam = ($mapper eq "STAR") ? "Aligned.sorted.sam": ($mapper eq "TopHat2") ? "accepted_hits.sam" : "none";
    # If unsorted SAM (star)
    #my $sam = ($mapper eq "STAR") ? "Aligned.out.sam": ($mapper eq "TopHat2") ? "accepted_hits.sam" : "none";
    #my $sam = $seqFileName.".sam";
    
    print "Splitting genomic mapping per chromosome...\n";
    split_SAM_per_chr(\%chr_sizes,$work_dir,$seqFileName,$run_name,$sam);
    
    # Init multi core
    my $pm = new Parallel::ForkManager($cores);
    print "   Using ".$cores." core(s)\n   ---------------\n";
    
    foreach my $chr (keys %chr_sizes){
        
        ### Start parallel process
        $pm->start and next;
        
        ### DBH per process
        my $dbh = dbh($dsn_sqlite_results,$us_sqlite_results,$pw_sqlite_results);
        
        ### RIBO parsing
        #print "   Starting RIBO parsing of genomic mappings on chromosome ".$chr."\n";
        my $hits = RIBO_parsing_genomic_per_chr($work_dir,$seqFileName,$run_name,$sam,$chr);
        
        ### To File
        #print "   Storing chromosome ".$chr." results in File\n";
        store_in_file_per_chr($hits,$dbh,$seqFileName,$chr,$run_name);
        
        ### Finish
        print "* Finished chromosome ".$chr."\n";
        $dbh->disconnect();
        $pm->finish;
    }
    
    # Finish all subprocesses
    $pm->wait_all_children;
    
    # Create indexes on riboseq tables
    
    
    my $table_name = "count_".$seqFileName;
    
    my $index1_st =  "create index if not exists ".$table_name."_chr on ".$table_name." (chr)";
    my $index2_st = "create index if not exists ".$table_name."_strand on ".$table_name." (strand)";
    
    my $system_cmd1 = $sqlite_loc." ".$db_sqlite_results." \"".$index1_st."\"";
    my $system_cmd2 = $sqlite_loc." ".$db_sqlite_results." \"".$index2_st."\"";
    
    system($system_cmd1);
    system($system_cmd2);
    
    
    ###################################
    #Start combining/generating output#
    ###################################
    
    ###SQLite DUMP
    
    # Gather all temp_chrom_csv files and dump import into SQLite DB
    my $temp_csv_all = $TMP."/genomic/".$run_name."_".$seqFileName.".csv";
    system("touch ".$temp_csv_all);
    
    foreach my $chr (keys %chr_sizes){
        my $temp_csv = $TMP."/genomic/".$run_name."_".$seqFileName."_".$chr."_tmp.csv";
        system ("cat ".$temp_csv." >>". $temp_csv_all);
    }
    #Remove _tmp.csv files
    system("rm -rf ".$TMP."/genomic/".$run_name."_".$seqFileName."_*_tmp.csv");
    
    system($sqlite_loc." -separator , ".$db_sqlite_results." \".import ".$temp_csv_all." ".$table_name."\"")== 0 or die "system failed: $?";
    system ("rm -rf ".$temp_csv_all);
   
    ###BEDGRAPH/BED output RIBOseq
    
    # Gather all + give header
    # BEDGRAPH /split for sense and antisense (since double entries, both (anti)sense cannot be visualized)
    my $bed_allgr_sense = $TMP."/genomic/".$run_name."_".$seqFileName."_sense.bedgraph";
    my $bed_allgr_antisense = $TMP."/genomic/".$run_name."_".$seqFileName."_antisense.bedgraph";
    open (BEDALLGRS,">".$bed_allgr_sense) || die "Cannot open the BEDGRAPH sense output file";
    open (BEDALLGRAS,">".$bed_allgr_antisense) || die "Cannot open the BEDGRAPH antisense output file";
    print BEDALLGRS "track type=bedGraph name=\"".$run_name."_".$seqFileName."_s\" description=\"".$run_name."_".$seqFileName."_s\" visibility=full color=3,189,0 priority=20\n";
    print BEDALLGRAS "track type=bedGraph name=\"".$run_name."_".$seqFileName."_as\" description=\"".$run_name."_".$seqFileName."_as\" visibility=full color=239,61,14 priority=20\n";
    close(BEDALLGRS);
    close(BEDALLGRAS);
    
    # BED has simple header for H2G2 upload
    my $bed_all = $TMP."/genomic/".$run_name."_".$seqFileName.".bed";
    open (BEDALL,">".$bed_all) || die "Cannot open the BED output file";
    print BEDALL "track name=\"".$run_name."_".$seqFileName."\" description=\"".$run_name."_".$seqFileName."\"\n";
    close(BEDALL);
    
    #Write temp files into bundled file (both BED and BEDGRAPH)
    foreach my $chr (keys %chr_sizes){
        if ($chr eq "MT") { next; } # Skip mitochondrial mappings
        my $temp_bed = $TMP."/genomic/".$run_name."_".$seqFileName."_".$chr."_tmp.bed";
        system ("cat ".$temp_bed." >>". $bed_all);
        my $temp_bedgr_s = $TMP."/genomic/".$run_name."_".$seqFileName."_".$chr."_s_tmp.bedgraph";
        my $temp_bedgr_as = $TMP."/genomic/".$run_name."_".$seqFileName."_".$chr."_as_tmp.bedgraph";
        
        system ("cat ".$temp_bedgr_s." >>". $bed_allgr_sense);
        system ("cat ".$temp_bedgr_as." >>". $bed_allgr_antisense);
    }
    
    #Remove _tmp.bed/_tmp.bedgraph and sorted sam files and move bundled files into output folder
    #    system("mv ". $bed_allgr_sense." ".$work_dir."/output/".$run_name."_".$seqFileName."_s.bedgraph");
    #    system("mv ". $bed_allgr_antisense." ".$work_dir."/output/".$run_name."_".$seqFileName."_as.bedgraph");
    system("mv ". $bed_allgr_sense." ".$bedgr_s);
    system("mv ". $bed_allgr_antisense." ".$bedgr_as);
    system("mv ". $bed_all." ".$work_dir."/output/".$run_name."_".$seqFileName.".bed");
    system("rm -rf ".$TMP."/genomic/".$run_name."_".$seqFileName."_*_tmp.bed");
    system("rm -rf ".$TMP."/genomic/".$run_name."_".$seqFileName."_*_s_tmp.bedgraph");
    system("rm -rf ".$TMP."/genomic/".$run_name."_".$seqFileName."_*_as_tmp.bedgraph");
    system("rm -rf ".$TMP."/genomic/".$seqFileName."_*");
    system("rm -rf ".$TMP."/genomic/");
}


### GET CHR SIZES ###
sub get_chr_sizes {
    
    # Catch
    my $chromosome_sizes = $_[0];
    
    # Work
    my %chr_sizes;
    open (Q,"<".$chromosome_sizes) || die "Cannot open chr sizes input\n";
    while (<Q>){
        my @a = split(/\s+/,$_);
        $chr_sizes{$a[0]} = $a[1];
    }
    
    return(\%chr_sizes);
}

### GET CHRs ###

sub get_chrs {
    
    # Catch
    my $db          =   $_[0];
    my $us          =   $_[1];
    my $pw          =   $_[2];
    my $chr_file    =   $_[3];
    my $assembly    =   $_[4];
    
    # Init
    my $chrs    =   {};
    my $dbh     =   dbh($db,$us,$pw);
    my ($line,@chr,$coord_system_id,$seq_region_id,@ids,@coord_system);
    
    # Get chrs from Chr_File
    open (Q,"<".$chr_file) || die "Cannot open chr sizes input\n";
    while ($line = <Q>){
        $line =~ /^(\S*)/;
        push (@chr,$1);
    }
    
    # Get correct coord_system_id
    my $query = "SELECT coord_system_id FROM coord_system where name = 'chromosome' and version = '".$assembly."'";
	my $sth = $dbh->prepare($query);
	$sth->execute();
    @coord_system = $sth->fetchrow_array;
    $coord_system_id = $coord_system[0];
    $sth->finish();
   	
    # Get chrs with seq_region_id
    my $chr;
    foreach (@chr){
        if ($species eq "fruitfly"){
            if($_ eq "M"){
                $chr = "dmel_mitochondrion_genome";
            }else{
                $chr = $_;
            }
        }else {
            $chr = $_;
        }
        
        my $query = "SELECT seq_region_id FROM seq_region where coord_system_id = ".$coord_system_id."  and name = '".$chr."' ";
        my $sth = $dbh->prepare($query);
        $sth->execute();
        @ids = $sth->fetchrow_array;
        $seq_region_id = $ids[0];
        $chrs->{$_}{'seq_region_id'} = $seq_region_id;
        $sth->finish();
    }
    
    #Disconnect DBH
    $dbh->disconnect();
	
	# Return
	return($chrs);
    
}

### SPLIT SAM PER CHR ###
sub split_SAM_per_chr {
    
    # Catch
    my %chr_sizes = %{$_[0]};
    my $work_dir = $_[1];
    my $seqFileName   = $_[2];
    my $run_name       = $_[3];
    my $sam = $_[4];
    
    my @splitsam = split(/\//, $sam );
    my $samFileName = $splitsam[$#splitsam];
    
    my $directory = $work_dir."/".$mapper."/".$seqFileName."/";
    my ($chr,@mapping_store,$file_in_loc,$file_in,$file_out);
    
    #Create chromosome sub directory in temp
    system("mkdir -p ".$TMP."/genomic/");
    system("rm -f ".$TMP."/genomic/".$samFileName."_*");   # Delete existing
    
    # Touch per chr
    foreach $chr (keys %chr_sizes){
        system("touch ".$TMP."/genomic/".$samFileName."_".$chr);   # Touch new
    }
    
    ## Split files into chromosomes
    $file_in_loc = $sam;
    system ("mv ". $file_in_loc ." ".$TMP."/genomic/");
    $file_in = $TMP."/genomic/".$samFileName;
    
    # Open
    open (I,"<".$file_in) || die "Cannot open ".$file_in." file\n";

    #For sorted SAM file (genomic location)
#    # Parse
#    my $prev_chr = "";
#    $file_out = $TMP."/genomic/".$sam;
#    while(my $line=<I>){
#        
#        #Skip annotation lines
#        if ($line =~ m/^@/) { next; }
#        
#        #Process alignment line
#        @mapping_store = split(/\t/,$line);
#        
#        # Unique vs. (Unique+Multiple) alignment selection
#        # NH:i:1 means that only 1 alignment is present
#        # HI:i:xx means that this is the xx-st ranked (for Tophat ranking starts with 0, for STAR ranking starts with 1)
#        if ($unique eq "Y") {
#            next unless (($mapping_store[4] == 255 && $mapper eq "STAR") || ($line =~ m/NH:i:1\D/ && $mapper eq "TopHat2"));
#        }
#        elsif ($unique eq "N") {
#            #If multiple: best scoring or random (if equally scoring) is chosen
#            next unless (($mapping_store[12] eq "HI:i:1" && $mapper eq "STAR") || (($line =~ m/HI:i:0/ || $line =~ m/NH:i:1\D/) && $mapper eq "TopHat2"));
#        }
#        
#        @mapping_store = split(/\t/,$line);
#        $chr = $mapping_store[2];
#        
#        # Write off
#        if ($prev_chr ne $chr) {
#            # Close previous chr file if you switch chromosomes in sam file, unless it's the first chromosome in sam file (i.e. when prev_chr = "")
#            if ($prev_chr ne "") { close(A); }
#            # Open new chr output file if you switch chromosomes
#            open (A,">>".$file_out."_".$chr) || die "Cannot open the sep file";
#        }
#        print A $line;
#    }
#    #Close last chr file
#    close(A);
#    # Close
#    close(I);

    #For unsorted SAM file (genomic location)
    my $prev_chr="0";
    
    while(my $line=<I>){
        
        #Skip annotation lines
        if ($line =~ m/^@/) { next; }
        
        #Process alignment line
        @mapping_store = split(/\t/,$line);
        $chr = $mapping_store[2];
        
        # Unique vs. (Unique+Multiple) alignment selection
        # NH:i:1 means that only 1 alignment is present
        # HI:i:xx means that this is the xx-st ranked (for Tophat ranking starts with 0, for STAR ranking starts with 1)
        if ($unique eq "Y") {
            next unless (($mapping_store[4] == 255 && $mapper eq "STAR") || ($line =~ m/NH:i:1\D/ && $mapper eq "TopHat2"));
        }
        elsif ($unique eq "N") {
            #If multiple: best scoring or random (if equally scoring) is chosen
            #next unless (($mapping_store[12] eq "HI:i:1" && $mapper eq "STAR") || (($line =~ m/HI:i:0/ || $line =~ m/NH:i:1\D/) && $mapper eq "TopHat2"));
            
            #Keep all mappings, also MultipleMapping locations are available (alternative to pseudogenes mapping) GM:07-10-2013
            #Note that we only retain the up until <15 multiple locations (to avoid including TopHat2 peak @ 15)
            #next unless ( $mapper eq "STAR" || $mapper eq "TopHat2");
            next unless ( $line !~ m/NH:i:16/ );
            
        }
        
        # Write off
        if ($prev_chr ne $chr) {
            if ($prev_chr ne "0") { close(A);}
            $file_out = $TMP."/genomic/".$samFileName;
            open (A,">>".$file_out."_".$chr) || die "Cannot open the sep file";
            print A $line;
        }
        elsif ($prev_chr eq $chr) {
            print A $line;
        }
        $prev_chr = $chr;
    
    }

    # Close
    close(A);
    close(I);
    
    # Move back from TMP folder to original location
    system ("mv ". $file_in ." ".$sam);
}


### RIBO PARSE PER CHR ###
sub RIBO_parsing_genomic_per_chr {
    
    #Catch
    my $work_dir = $_[0];
    my $seqFileName = $_[1];
    my $run_name = $_[2];
    my $sam = $_[3];
    my $chr = $_[4];
    
    my @splitsam = split(/\//, $sam );
    my $samFileName = $splitsam[$#splitsam];
    
    #my $mapCount; my $mapFilterCount;
    
    #Initialize
    my $directory = $work_dir."/".$mapper."/".$seqFileName."/";
    my $hits_genomic = {};
    my $plus_count = 0; my $min_count = 0; my $lineCount = 0;
    my ($genmatchL,$offset,$start,$intron_total,$extra_for_min_strand,$pruned_alignmentL,$prunedalignment);
    my $lendistribution;
    
    open (LD,">".$TMP."/LD_".$seqFileName."_".$chr.".txt");
    open (I,"<".$TMP."/genomic/".$samFileName."_".$chr) || die "Cannot open ".$samFileName." file\n";
    #open (LL,">".$TMP."/genomic/LL_".$chr) || die "Cannot open LL file\n";
    while(my $line=<I>){
        
        $lineCount++;
        #progressbar($lineCount);
        
        #Process alignment line
        my @mapping_store = split(/\t/,$line);
        
        #Get strand specifics
        # Sam flag is bitwise. (0x10 SEQ being reverse complemented)
        # 0x10 = 16 in decimal. -> negative strand.
        my $strand = ($mapping_store[1] & 16) ? "-": "+";
        my $CIGAR = $mapping_store[5];
        
        #Parse CIGAR to obtain offset,genomic matching length and total covered intronic region before reaching the offset
        if($species eq 'fruitfly'){
            ($offset,$genmatchL,$intron_total,$extra_for_min_strand,$pruned_alignmentL,$prunedalignment) = parse_dme_RIBO_CIGAR($CIGAR,$strand);
            $lendistribution->{$genmatchL}++;
            if ($pruned_alignmentL > 0){
                if ($strand eq "+") { $plus_count++;} elsif ($strand eq "-") { $min_count++; }
                foreach my $n (keys %{$prunedalignment}){
                    $start = ($strand eq "+") ? $mapping_store[3] + $prunedalignment->{$n}{'intron_total'} + $n -1: ($strand eq "-") ? $mapping_store[3] -$n - $prunedalignment->{$n}{'intron_total'} + $extra_for_min_strand : "";
                    if ( $genmatchL >= 25 && $genmatchL <= 34) {
                        if ( exists $hits_genomic->{$chr}->{$start}->{$strand} ){
                            $hits_genomic->{$chr}->{$start}->{$strand} = $hits_genomic->{$chr}->{$start}->{$strand} + (1/$pruned_alignmentL);
                        }else {
                            $hits_genomic->{$chr}->{$start}->{$strand} = 0;
                            $hits_genomic->{$chr}->{$start}->{$strand} = $hits_genomic->{$chr}->{$start}->{$strand} + (1/$pruned_alignmentL);
                        }
                    }
                }
            }
        }else{
            ($offset,$genmatchL,$intron_total,$extra_for_min_strand) = parse_RIBO_CIGAR($CIGAR,$strand);
            $lendistribution->{$genmatchL}++;
            #Determine genomic position based on CIGAR string output and mapping position and direction
            $start = ($strand eq "+") ? $mapping_store[3] + $offset + $intron_total : ($strand eq "-") ? $mapping_store[3] - $offset - $intron_total + $extra_for_min_strand -1 : "";
            if ( $genmatchL >= 29 && $genmatchL <= 34) {
                $hits_genomic->{$chr}->{$start}->{$strand}++;
                if ($strand eq "+") { $plus_count++;} elsif ($strand eq "-") { $min_count++; }
            }
        }
        # Parse sense mappers
#        if ($mapping_store[1] == 0 || $mapping_store[1] == 256) {
#            
#            # Look at CIGAR string to see wether last bases are mismatch (due to AdaptorSeq)
#            $readL = ($mapping_store[5] =~ m/(\d+)S$/) ? length($mapping_store[9]) - $1 : length($mapping_store[9]);
#            $readL2 = $readL;
#            # Look at CIGAR string to see wether first base is mismatch and adapt length of read accordingly
#            # Sometimes first base is still from construct
#            $readL = ($mapping_store[5] =~ m/^1S/) ? $readL - 1 : $readL;
#            $readL3 = $readL;
#            #print "+\t". $mapping_store[9]."\t".$mapping_store[3]."\t".$mapping_store[5] ."\t". length($mapping_store[9]) . "\t" . $readL . "\n";
#            
#            # A-site detection
#            # Only map the first base of A-site (by using the offset ~ dependent on read-length)
#            # That means that the ribosome profile is mapped to only one base
#            $offset = get_offset($readL);
#            $start = $mapping_store[3] + $offset;
#            #Take into account the splice junctions
#            $mapping_store[5] =~ /(\d+)M(\d+)N(\d+)M/;
#            $start = ($1 < $offset) ? $start + $2 : $start;
#            
#            # O stands for sense
#            # Only profiles with lengt between 28-35 are taken into account
#            if ( $readL >= 28 && $readL <= 35) {
#                $hits_genomic->{$chr}->{$start}->{"+"}++;
#                $plus_count++;
#                print LL "+,$mapping_store[1],$mapping_store[5],$readL1,$readL2,$readL3,$offset\n";
#            }
#            
#        }
#        
#        # Parse the antisense mappers
#        elsif ($mapping_store[1] == 16 || $mapping_store[1] == 272) {
#            $readL = ($mapping_store[5] =~ m/^(\d+)S/) ? length($mapping_store[9]) - $1 : length($mapping_store[9]);
#            $readL2 = $readL;
#            $readL = ($mapping_store[5] =~ m/1S$/) ? $readL - 1 : $readL;
#            $readL3 = $readL;
#            # A-site detection
#            $offset = get_offset($readL);
#            
#            #$start = $mapping_store[3] + ($readL-1) - $offset;
#            $start = $mapping_store[3] + ($readL) - $offset;
#            
#            #Take into account the splice junctions
#            $mapping_store[5] =~ /(\d+)M(\d+)N(\d+)M/;
#            $start = ($3 < $offset) ? $start - $2 : $start;
#            
#            
#            # 1 stands for antisense
#            # Only profiles with lengt between 28-35 are taken into account
#            if ( $readL >= 28 && $readL <= 35) {
#                $hits_genomic->{$chr}->{$start}->{"-"}++;
#                $min_count++;
#                print LL "-,$mapping_store[1],$mapping_store[5],$readL1,$readL2,$readL3,$offset\n";
#            }
#        }
    }
    #print "$lineCount\n";
    my $cnttot = $plus_count + $min_count;
    #print "plus = $plus_count\t min = $min_count\n";
    #print "mapCount = $lineCount, mapFilterCount = $cnttot\n";
    for my $key ( sort { $a <=> $b } keys %$lendistribution ) {
        print LD "$key\t$lendistribution->{$key}\n";
    }
    #print Dumper($lendistribution);
    
    close(LD);
    close(I);
    return($hits_genomic);
}


### STORE IN FILE PER CHR ###
sub store_in_file_per_chr {
    
    # Catch
    my $hits = $_[0];
    my $dbh  = $_[1];
    my $seqFileName = $_[2];
    my $chromosome = $_[3];
    my $run_name = $_[4];
    
    my $directory = $work_dir."/".$mapper."/".$seqFileName."/";
    
    # Create table if not exist
    my $query_table = "CREATE TABLE IF NOT EXISTS `count_".$seqFileName."` (
    `chr` char(50) NOT NULL default '',
    `strand` char(1) NOT NULL default '0',
    `start` int(10) NOT NULL default '0',
    `count` float default NULL)";
    
    #print "$query_table\n";
    $dbh->do($query_table);
    
    # Disco
    $dbh->disconnect;
    
    #Init temporary csv-file/bed-file/bedgraph-file
    my $temp_csv = $TMP."/genomic/".$run_name."_".$seqFileName."_".$chromosome."_tmp.csv";
    my $temp_bed = $TMP."/genomic/".$run_name."_".$seqFileName."_".$chromosome."_tmp.bed";
    my $temp_bedgr_s = $TMP."/genomic/".$run_name."_".$seqFileName."_".$chromosome."_s_tmp.bedgraph";
    my $temp_bedgr_as = $TMP."/genomic/".$run_name."_".$seqFileName."_".$chromosome."_as_tmp.bedgraph";
    
    open TMP, "+>>".$temp_csv or die $!;
    open TMPBED, "+>>".$temp_bed or die $!;
    open TMPBEDGRS, "+>>".$temp_bedgr_s or die $!;
    open TMPBEDGRAS, "+>>".$temp_bedgr_as or die $!;
    
    
    #print Dumper($hits);
    # Store
    #print Dumper($hits->{$chromosome});
    foreach my $start (sort {$a <=> $b} keys %{$hits->{$chromosome}}){
        
        # Vars
        my $size = 1; #$bins->{$start}->{"o"} - $bins->{$start}->{"a"} + 1;
        my $plus_count = ($hits->{$chromosome}->{$start}->{'+'}) ? $hits->{$chromosome}->{$start}->{'+'}/$size : 0;
        my $min_count =  ($hits->{$chromosome}->{$start}->{'-'}) ? $hits->{$chromosome}->{$start}->{'-'}/$size : 0;
        #print "$plus_count,$min_count\n"; exit;
        my $start_pos = $start;
        #Convert to 0-based (BED=0-based instead of SAM=1-based)
        my $start_pos_Obased = $start_pos -1;
        my $sign;
        
        my $strand;
        # To db
        if ($min_count != 0) {
            $strand = "-1";
            $sign ="-";
            $min_count = sprintf("%.3f", $min_count);
            #my $query = "INSERT INTO bins_".$run_name."_".$seqFileName." (chr,strand,start,count) VALUES (\'".$chromosome."\',\'".$strand."\',\'".$start_pos."\',\'".$min_count."\')";
            #print "$query\n";
            #$dbh->do($query);
            
            print TMP $chromosome.",".$strand.",".$start_pos.",".$min_count."\n";
            print TMPBED "chr$chromosome\t$start_pos_Obased\t$start_pos\t \t$min_count\t$sign\t0\t0\t239,34,5\t\t\t\t\t\n";
            print TMPBEDGRAS "chr$chromosome\t$start_pos_Obased\t$start_pos\t$sign$min_count\n";
            
        }
        if ($plus_count != 0) {
            $strand = "1";
            $sign ="+";
            $plus_count = sprintf("%.3f", $plus_count);
            #my $query = "INSERT INTO bins_".$run_name."_".$seqFileName." (chr,strand,start,count) VALUES (\'".$chromosome."\',\'".$strand."\',\'".$start_pos."\',\'".$plus_count."\')";
            #print "$query\n";
            #$dbh->do($query);
            print TMP $chromosome.",".$strand.",".$start_pos.",".$plus_count."\n";
            print TMPBED "chr$chromosome\t$start_pos_Obased\t$start_pos\t \t$plus_count\t$sign\t0\t0\t23,170,35\t\t\t\t\t\n";
            print TMPBEDGRS "chr$chromosome\t$start_pos_Obased\t$start_pos\t$plus_count\n";

            #chr1    4772791 4774053 uc007afd_ENSMUSG00000033845_248_AATATGG_internal-out-of-frame   0       -       0       0       23,170,35      2       23,22,  0,1240,
            #chr, start, end, name, score, strand, thickStart, thickEnd, itemRGB, blockCount, blockSizes, blockStarts

        }
    }
    close(TMP);
    close(TMPBED);
    close(TMPBEDGRS);
    close(TMPBEDGRAS);
}

#Parse dme RIBO_CIGARS to obtain pruned alignment,read mapping length and total intronic length for each pruned alignment position
sub parse_dme_RIBO_CIGAR {
    
    #Catch
    my $CIGAR = $_[0];
    my $strand = $_[1];
    
    my $CIGAR_SPLIT = splitCigar($CIGAR);
    my $CIGAR_SPLIT_STR = [];
    @$CIGAR_SPLIT_STR = ($strand eq "-") ? reverse @$CIGAR_SPLIT : @$CIGAR_SPLIT;
    my $op_total = @$CIGAR_SPLIT_STR;
    #print "number of operations = $op_total\n";
    # print meta information
    #print "Cigar: $CIGAR\n";
    #print "Strand: $strand\n";
    
    my $genmatchL = 0;
    my $op_count = 0;
    #To keep track of total length of genomic + intron (negative strand, reverse position)
    my $extra_for_min_strand = 0;
    #Loop over operation to get total mapping length to calculate the A-site offset
    # and to get total extra length for min_strand (i.e. S(not 5adapt nor 1stTRIM), N (splicing), M, D,I)
    foreach my $operation (@$CIGAR_SPLIT_STR) {
        my $op_length = $operation->[0];
        my $op_type = $operation->[1];
        $op_count++;
        
        if($op_type =~ /^S$/) {
            #Trim leading substitution if only 1 substitution @ 5'
            if ($op_count == 1 && $op_length == 1) {
                next;
            }
            #Clip trailing adaptor substitution
            elsif ($op_count == $op_total) {
                next;
            }
            #Other substitutions are added to RIBO-read genomic-match length
            #And also added to the total matching count
            else {
                $genmatchL = $genmatchL + $op_length;
                $extra_for_min_strand = $extra_for_min_strand + $op_length;
            }
        }
        #Sum matching operations until the offset is reached, then change status to "Y"
        elsif($op_type =~ /^M$/) {
            $genmatchL = $genmatchL + $op_length;
            $extra_for_min_strand = $extra_for_min_strand + $op_length;
        }
        #Insertions elongate the readL and the insertion size is added to the total matching count
        elsif($op_type =~ /^I$/) {
            $genmatchL = $genmatchL + $op_length;
            $extra_for_min_strand = $extra_for_min_strand + $op_length;
        }
        #Splice intronic regions are added to the extra_for_min_strand
        elsif($op_type =~ /^N$/) {
            $extra_for_min_strand = $extra_for_min_strand + $op_length;
        }
    }
    #print "total mapped sequence = $genmatchL\n";
    my $offset = 12;
    my $match_count_total = 0;
    $op_count = 0;
    
    #Create hash for pruned alignment.
    my $prunedalignmentL = $genmatchL - (2 * $offset);
    my $prunedalignment = {};
    my $pruned_alignment_position;
    my $intron_total = 0;
    
    #Return if genmatchL too short
    if ($prunedalignmentL <= 0) {
        return ($offset,$genmatchL,0,$extra_for_min_strand,$prunedalignmentL,$prunedalignment);
    }
    
    #Run over each pruned alignment position
    for(my $i=1;$i<=$prunedalignmentL;$i++){
        
        my $offset_covered = "N";
        $intron_total = 0;
        $match_count_total = 0;
        $op_count = 0;
        $pruned_alignment_position = $offset + $i;
        #print "pruned alignment position: ".$i."\n";
        #print Dumper($CIGAR_SPLIT_STR);
        
        #Loop over operations to caculate the total intron length
        foreach my $operation (@$CIGAR_SPLIT_STR) {
            my $op_length = $operation->[0];
            my $op_type = $operation->[1];
            $op_count++;
            #print "$op_type,$op_length\n";
            
            if($op_type =~ /^S$/) {
                #Trim leading substitution if only 1 substitution @ 5'
                if ($op_count == 1 && $op_length == 1) {
                    next;
                }
                #Clip trailing adaptor substitution
                elsif ($op_count == $op_total) {
                    next;
                }
                #Other substitutions are added to RIBO-read genomic-match length
                #And also added to the total matching count
                else {
                    $match_count_total = $match_count_total + $op_length;
                    if ($match_count_total >= $pruned_alignment_position) {
                        $offset_covered = "Y";
                        last;
                    }
                }
            }
            #Sum matching operations until the offset is reached, then change status to "Y"
            elsif($op_type =~ /^M$/) {
                $match_count_total = $match_count_total + $op_length;
                if ($match_count_total >= $pruned_alignment_position) {
                    $offset_covered = "Y";
                    last;
                }
            }
            #Sum intronic region lengths untill the offset has been covered by the matching operations
            elsif($op_type =~ /^N$/ && $offset_covered eq "N") {
                $intron_total = $intron_total + $op_length;
                #print "intron_total = ".$intron_total." for a CGIAR string = ".$operation->[0]."\n";
            }
            #Deletion are not counted for the readL
            elsif($op_type =~ /^D$/) {
                next;
                #$genmatchL = $genmatchL - $op_length;
            }
            #Insertions elongate the readL and the insertion size is added to the total matching count
            elsif($op_type =~ /^I$/) {
                $match_count_total = $match_count_total + $op_length;
                if ($match_count_total >= $pruned_alignment_position) {
                    $offset_covered = "Y";
                    last;
                }
            }
            #print "$match_count_total,$offset_covered,$offset\n";
        }
        
        #Save in prunedalignment_hash
        $prunedalignment->{$pruned_alignment_position}{'offset_covered'} = $offset_covered;
        $prunedalignment->{$pruned_alignment_position}{'intron_total'} = $intron_total;
    }
    
    return($offset,$genmatchL,$intron_total,$extra_for_min_strand,$prunedalignmentL,$prunedalignment);
}

#Parse RIBO_CIGARS to obtain offset,genomic read mapping length and total intronic length before offset is reached
sub parse_RIBO_CIGAR {
    
    #Catch
    my $CIGAR = $_[0];
    my $strand = $_[1];
    
    my $CIGAR_SPLIT = splitCigar($CIGAR);
    my $CIGAR_SPLIT_STR = [];
    @$CIGAR_SPLIT_STR = ($strand eq "-") ? reverse @$CIGAR_SPLIT : @$CIGAR_SPLIT;
    my $op_total = @$CIGAR_SPLIT_STR;
    #print "number of operations = $op_total\n";
    # print meta information
    #print "Cigar: $CIGAR\n";
    #print "Strand: $strand\n";
    
    my $genmatchL = 0;
    my $op_count = 0;
    #To keep track of total length of genomic + intron (negative strand, reverse position)
    my $extra_for_min_strand = 0;
    #Loop over operation to get total mapping length to calculate the A-site offset
    # and to get total extra length for min_strand (i.e. S(not 5adapt nor 1stTRIM), N (splicing), M, D,I)
    foreach my $operation (@$CIGAR_SPLIT_STR) {
        my $op_length = $operation->[0];
        my $op_type = $operation->[1];
        $op_count++;
        
        if($op_type =~ /^S$/) {
            #Trim leading substitution if only 1 substitution @ 5'
            if ($op_count == 1 && $op_length == 1) {
                next;
            }
            #Clip trailing adaptor substitution
            elsif ($op_count == $op_total) {
                next;
            }
            #Other substitutions are added to RIBO-read genomic-match length
            #And also added to the total matching count
            else {
                $genmatchL = $genmatchL + $op_length;
                $extra_for_min_strand = $extra_for_min_strand + $op_length;
            }
        }
        #Sum matching operations until the offset is reached, then change status to "Y"
        elsif($op_type =~ /^M$/) {
            $genmatchL = $genmatchL + $op_length;
            $extra_for_min_strand = $extra_for_min_strand + $op_length;
        }
        #Insertions elongate the readL and the insertion size is added to the total matching count
        elsif($op_type =~ /^I$/) {
            $genmatchL = $genmatchL + $op_length;
            $extra_for_min_strand = $extra_for_min_strand + $op_length;
        }
        #Splice intronic regions are added to the extra_for_min_strand
        elsif($op_type =~ /^N$/) {
            $extra_for_min_strand = $extra_for_min_strand + $op_length;
        }
    }
    #print "total mapped sequence = $genmatchL\n";
    my $offset = get_offset($genmatchL);
    my $match_count_total = 0;
    $op_count = 0;
    my $offset_covered = "N";
    my $intron_total = 0;
    #Loop over operations to caculate the total intron length
    foreach my $operation (@$CIGAR_SPLIT_STR) {
        my $op_length = $operation->[0];
        my $op_type = $operation->[1];
        $op_count++;
        #print "$op_type,$op_length\n";
        if($op_type =~ /^S$/) {
            #Trim leading substitution if only 1 substitution @ 5'
            if ($op_count == 1 && $op_length == 1) {
                next;
            }
            #Clip trailing adaptor substitution
            elsif ($op_count == $op_total) {
                next;
            }
            #Other substitutions are added to RIBO-read genomic-match length
            #And also added to the total matching count
            else {
                $match_count_total = $match_count_total + $op_length;
                if ($match_count_total >= $offset) {
                    $offset_covered = "Y";
                    last;
                }
            }
        }
        #Sum matching operations until the offset is reached, then change status to "Y"
        elsif($op_type =~ /^M$/) {
            $match_count_total = $match_count_total + $op_length;
            if ($match_count_total >= $offset) {
                $offset_covered = "Y";
                last;
            }
        }
        #Sum intronic region lengths untill the offset has been covered by the matching operations
        elsif($op_type =~ /^N$/ && $offset_covered eq "N") {
            $intron_total = $intron_total + $op_length;
            
        }
        #Deletion are not counted for the readL
        elsif($op_type =~ /^D$/) {
            next;
            #$genmatchL = $genmatchL - $op_length;
        }
        #Insertions elongate the readL and the insertion size is added to the total matching count
        elsif($op_type =~ /^I$/) {
            $match_count_total = $match_count_total + $op_length;
            if ($match_count_total >= $offset) {
                $offset_covered = "Y";
                last;
            }
        }
        #print "$match_count_total,$offset_covered,$offset\n";
    }
    
    return($offset,$genmatchL,$intron_total,$extra_for_min_strand)
}


### CALCULATE A-SITE OFFSET ###
sub get_offset {
    
    #Catch
    my $len = $_[0];
    
    my $offset = ($len >= 34) ? 14 :
    ($len <= 30) ? 12 :
    13;
    
    return($offset);
}


# Given a Cigar string return a double array
# such that each sub array contiains the [ length_of_operation, Cigar_operation]
sub splitCigar {
    my $cigar_string = shift;
    my @returnable;
    my (@matches) = ($cigar_string =~ /(\d+\w)/g);
    foreach (@matches) {
        my @operation = ($_ =~ /(\d+)(\w)/);
        push @returnable, \@operation;
    }
    return \@returnable;
}


### PROGRESS BAR ###
sub progressbar {
    $| = 1;
    my $a=$_[0];
    if($a<0) {
        for(my $s=0;$s<-$a/1000000;$s++) {
            print " ";
        }
        print "                                \r";
    }
    my $seq="";
    if($a%50==0) {
        for(my $s=0;$s<$a/1000000;$s++) {
            $seq.="►";
        }
    }
    if(($a/1000000)%2==0) { print "  ✖ Crunching ".$seq."\r"; }
    if(($a/1000000)%2==1) { print "  ✚ Crunching ".$seq."\r"; }
}