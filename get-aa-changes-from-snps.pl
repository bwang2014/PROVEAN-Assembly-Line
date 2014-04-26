#!/usr/bin/env perl
# Mike Covington
# created: 2014-04-24
#
# Description:
#
use strict;
use warnings;
use Log::Reproducible;
use autodie;
use feature 'say';
use Parallel::ForkManager;

my $threads = 3;

my $gff_file = "ITAG2.3_gene_models.gff3";
my @snp_file_list = @ARGV;
my $fa_file = "S_lycopersicum_chromosomes.2.40.fa";

my %cds;
open my $gff_fh, "<", $gff_file;
while (<$gff_fh>) {
    next if /^#/;
    chomp; # Columns: seqid source type start end score strand phase attribute
    my ( $seqid, $type, $start, $end, $strand, $phase, $attribute ) = (split /\t/)[0, 2..4, 6..8];
    next unless $type =~ /CDS/;
    my ($mrna) = $attribute =~ /Parent=mRNA:([^;]+);/;
    $cds{$seqid}{$mrna}{strand} = $strand;
    push @{$cds{$seqid}{$mrna}{cds}}, {start => $start, end => $end, phase => $phase };
}
close $gff_fh;


my $par1 = 'M82_n05';
my $par2 = 'PEN';
my %snps;
for my $snp_file (@snp_file_list) {

    open my $snp_fh, "<", $snp_file;
    <$snp_fh>;
    while (<$snp_fh>) {
        my ( $seqid, $pos, $ref, $alt, $alt_parent ) = split /\t/;
        next if $ref =~ /INS/;
        next if $alt =~ /del/;
        $snps{$seqid}{$pos}{par1} = $alt_parent eq $par1 ? $alt : $ref;
        $snps{$seqid}{$pos}{par2} = $alt_parent eq $par2 ? $alt : $ref;
    }
    close $snp_fh;

}

my $pm = new Parallel::ForkManager($threads);
for my $seqid ( sort keys %cds ) {
    next unless exists $snps{$seqid};
    my $pid = $pm->start and next;
    open my $aa_change_fh, ">", "aa-changes.$seqid";
    say $aa_change_fh join "\t", qw(gene length snp_count aa_substitution_count aa_substitutions);
    for my $mrna ( sort keys $cds{$seqid} ) {
        my $mrna_start = $cds{$seqid}{$mrna}{cds}->[0]->{start};
        my $mrna_end   = $cds{$seqid}{$mrna}{cds}->[-1]->{end};
        @{ $cds{$seqid}{$mrna}{snps} } = ();
        for my $pos ( sort { $a <=> $b } keys $snps{$seqid} ) {
            push @{ $cds{$seqid}{$mrna}{snps} }, $pos
                if ($pos >= $mrna_start && $pos <= $mrna_end );
        }

        my ( $par1_seq, $par2_seq )
            = get_seq( $fa_file, $seqid, $mrna_start, $mrna_end,
            $cds{$seqid}{$mrna}{snps},
            $snps{$seqid} );

        my $par1_spliced = '';
        my $par2_spliced = '';
        my $total_cds_length;
        for my $cds (@{$cds{$seqid}{$mrna}{cds}}) {
            my $cds_start = $cds->{start};
            my $cds_end = $cds->{end};

            $total_cds_length += $cds_end - $cds_start + 1;
            $par1_spliced .= substr $par1_seq, $cds_start - $mrna_start, $cds_end - $cds_start + 1;
            $par2_spliced .= substr $par2_seq, $cds_start - $mrna_start, $cds_end - $cds_start + 1;
        }

        if ( $cds{$seqid}{$mrna}{strand} eq '-' ) {
            reverse_complement( \$par1_spliced );
            reverse_complement( \$par2_spliced );
        }

        my $ref_protein = translate($par1_spliced);
        my $alt_protein = translate($par2_spliced);

        my @aa_changes = ();
        for my $idx (0 .. length($ref_protein) - 1) {
            my $ref_aa = substr $ref_protein, $idx, 1;
            my $alt_aa = substr $alt_protein, $idx, 1;
            next if $ref_aa eq $alt_aa;
            push @aa_changes, "$ref_aa:$alt_aa";
        }

        my $snp_count = scalar @{ $cds{$seqid}{$mrna}{snps} };
        my $aa_change_count = scalar @aa_changes;
        my $change_summary = join ",", @aa_changes;
        say $aa_change_fh join "\t", $mrna, $total_cds_length, $snp_count,
            $aa_change_count, $change_summary;
    }
    close $aa_change_fh;
    $pm->finish;
}
$pm->wait_all_children;

sub get_seq {
    my ( $fa_file, $seqid, $start, $end, $mrna_snps, $chr_snps ) = @_;
    my ( $header, @seq ) = `samtools faidx $fa_file $seqid:$start-$end`;
    chomp @seq;
    my $par1_seq = join "", @seq;
    # say $par1_seq;
    my $par2_seq = $par1_seq;
    for my $pos (@{$mrna_snps}) {
        my $par1 = $$chr_snps{$pos}{par1};
        my $par2 = $$chr_snps{$pos}{par2};
        my $offset = $pos - $start;
        substr $par1_seq, $offset, 1, $par1;
        substr $par2_seq, $offset, 1, $par2;
    }
    return $par1_seq, $par2_seq;
}

sub get_cds_snps {
    my ( $cds_start, $cds_end, $mrna_snps ) = @_;
    return grep { $_ >= $cds_start && $_ <= $cds_end } @$mrna_snps;
}

sub reverse_complement {    # Assumes no ambiguous codes
    my $seq = shift;
    $$seq = reverse $$seq;
    $$seq =~ tr/ACGTacgt/TGCAtgca/;
}

sub translate {
    my ( $nt_seq ) = @_;
    my $codon_table = codon_table();

    $nt_seq =~ tr/acgt/ACGT/;
    my $pos = 0;
    my $aa_seq;
    while ( $pos < length($nt_seq) - 2 ) {
        my $codon = substr $nt_seq, $pos, 3;
        my $amino_acid = $$codon_table{$codon};
        if ( defined $amino_acid ) {
            $aa_seq .= $amino_acid;
        }
        else {
            $aa_seq .= "X";
        }
        $pos += 3;
    }
    return $aa_seq;
}

sub codon_table {
    return {
        TTT => 'F', TCT => 'S', TAT => 'Y', TGT => 'C',
        TTC => 'F', TCC => 'S', TAC => 'Y', TGC => 'C',
        TTA => 'L', TCA => 'S', TAA => '-', TGA => '-',
        TTG => 'L', TCG => 'S', TAG => '-', TGG => 'W',
        CTT => 'L', CCT => 'P', CAT => 'H', CGT => 'R',
        CTC => 'L', CCC => 'P', CAC => 'H', CGC => 'R',
        CTA => 'L', CCA => 'P', CAA => 'Q', CGA => 'R',
        CTG => 'L', CCG => 'P', CAG => 'Q', CGG => 'R',
        ATT => 'I', ACT => 'T', AAT => 'N', AGT => 'S',
        ATC => 'I', ACC => 'T', AAC => 'N', AGC => 'S',
        ATA => 'I', ACA => 'T', AAA => 'K', AGA => 'R',
        ATG => 'M', ACG => 'T', AAG => 'K', AGG => 'R',
        GTT => 'V', GCT => 'A', GAT => 'D', GGT => 'G',
        GTC => 'V', GCC => 'A', GAC => 'D', GGC => 'G',
        GTA => 'V', GCA => 'A', GAA => 'E', GGA => 'G',
        GTG => 'V', GCG => 'A', GAG => 'E', GGG => 'G',
    };
}
