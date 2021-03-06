## no critic (RequireUseStrict, RequireUseWarnings, RequireTidyCode)
package Crispr::DB::PrimerPairAdaptor;

## use critic

# ABSTRACT: PrimerPairAdaptor object - object for storing PrimerPair objects in and retrieving them from a SQL database

use namespace::autoclean;
use Moose;
use English qw( -no_match_vars );
use DateTime;
use Readonly;
use Crispr::Primer;
use Crispr::PrimerPair;

extends 'Crispr::DB::BaseAdaptor';

=method new

  Usage       : my $primer_adaptor = Crispr::DB::PrimerPairAdaptor->new(
					db_connection => $db_connection,
                );
  Purpose     : Constructor for creating primer adaptor objects
  Returns     : Crispr::DB::PrimerPairAdaptor object
  Parameters  :     db_connection => Crispr::DB::DBConnection object,
  Throws      : If parameters are not the correct type
  Comments    : The preferred method for constructing a PrimerAdaptor is to use the
                get_adaptor method with a previously constructed DBConnection object

=cut

my $date_obj = DateTime->now();
Readonly my $PLATE_TYPE => '96';

# cache for primer_pair objects from db
has '_primer_pair_cache' => (
	is => 'ro',
	isa => 'HashRef',
    init_arg => undef,
    writer => '_set_primer_pair_cache',
    default => sub { return {}; },
);

=method store

  Usage       : $primer_pair_adaptor->store;
  Purpose     : method to store a primer_pair in the database.
  Returns     : 1 on Success.
  Parameters  : Crispr::PrimerPair
                Crispr::crRNA
  Throws      : If input is not correct type
  Comments    : 

=cut

sub store {
    # Primers must have already been added to the db
    my ( $self, $primer_pair, $crRNAs ) = @_;
    my $dbh = $self->connection->dbh();
    
    if( !$primer_pair ){
        confess "primer_pair must be supplied in order to add oligos to the database!\n";
    }
    if( !ref $primer_pair || !$primer_pair->isa('Crispr::PrimerPair') ){
        confess "Supplied object must be a Crispr::PrimerPair object, not ", ref $primer_pair, ".\n";
    }
    if( !$crRNAs ){
        confess "At least one crRNA_id must be supplied in order to add oligos to the database!\n";
    }
    elsif( ref $crRNAs ne 'ARRAY' ){
        confess "crRNA_ids must be supplied as an ArrayRef!\n";
    }
    foreach ( @{$crRNAs} ){
        if( !ref $_ || !$_->isa('Crispr::crRNA') ){
            confess "Supplied object must be a Crispr::crRNA object, not ", ref $_, ".\n";
        }
    }
    # statement to check primers exist in db
    my $check_primer_st = "select count(*) from primer where primer_id = ?;";
    # statement to add pair into primer_pair table
    my $pair_statement = "insert into primer_pair values( ?, ?, ?, ?, ?, ?, ?, ?, ? );";
    my $pair_to_crRNA_statement = "insert into amplicon_to_crRNA values( ?, ? );";
    
    $self->connection->txn(  fixup => sub {
        # check whether primers already exist in database
        foreach my $primer ( $primer_pair->left_primer, $primer_pair->right_primer ){
            if( !$self->check_entry_exists_in_db( $check_primer_st, [ $primer->primer_id ] ) ){
                confess "Couldn't locate primer, ", $primer_pair->left_primer->primer_name, "in the database!\n",
                "Primers must be added to database before primer pair info.\n";
            }
        }
        
        # add primer pair info
        my $sth = $dbh->prepare($pair_statement);
        $sth->execute(
            undef,
            $primer_pair->type,
            $primer_pair->left_primer->primer_id,
            $primer_pair->right_primer->primer_id,
            $primer_pair->seq_region,
            $primer_pair->seq_region_start,
            $primer_pair->seq_region_end,
            $primer_pair->seq_region_strand,
            $primer_pair->product_size,
        );
        my $last_id = $dbh->last_insert_id( 'information_schema', $self->dbname(), 'primer_pair', 'primer_pair_id' );
        $primer_pair->primer_pair_id( $last_id );
        
        $sth = $dbh->prepare($pair_to_crRNA_statement);
        foreach my $crRNA ( @{$crRNAs} ){
            $sth->execute(
                $last_id,
                $crRNA->crRNA_id,
            );
        }
        $sth->finish();
    } );
    return 1;
}

=method fetch_all_by_crRNA

  Usage       : $primer_pair_adaptor->fetch_all_by_crRNA( $crRNA );
  Purpose     : method to retrieve primer pairs for a crRNA using it's db id.
  Returns     : Crispr::PrimerPair
  Parameters  : Crispr::crRNA
  Throws      : If input is not correct type
  Comments    : 

=cut

sub fetch_all_by_crRNA {
    my ( $self, $crRNA, ) = @_;
    my $where_clause = 'amp.crRNA_id = ?';
    my $primer_pairs = $self->_fetch( $where_clause, [ $crRNA->crRNA_id ], );
    return $primer_pairs;
}

=method fetch_all_by_crRNAs

  Usage       : $primer_pair_adaptor->fetch_all_by_crRNAs( $crRNAs );
  Purpose     : method to retrieve primer pairs for a crRNAs using it's db id.
  Returns     : Crispr::PrimerPair
  Parameters  : Crispr::crRNAs
  Throws      : If input is not correct type
  Comments    : 

=cut

sub fetch_all_by_crRNAs {
    my ( $self, $crRNAs, ) = @_;
    my $where_clause = 'amp.crRNA_id = ?';
    my %pairs_seen;
    my @primer_pairs;
    foreach my $crRNA ( @{$crRNAs} ){
        my $primer_pairs = $self->fetch_all_by_crRNA_id( $crRNA->crRNA_id );
        foreach my $primer_pair ( @{$primer_pairs} ){
            if( !exists $pairs_seen{ $primer_pair->primer_pair_id } ){
                push @primer_pairs, $primer_pair;
                $pairs_seen{ $primer_pair->primer_pair_id } = 1;
            }
        }
    }
    return \@primer_pairs;
}

=method fetch_all_by_crRNA_id

  Usage       : $primer_pair_adaptor->fetch_all_by_crRNA_id( '1' );
  Purpose     : method to retrieve primer pairs for a crRNA using it's db id.
  Returns     : Crispr::PrimerPair
  Parameters  : Str (crRNA db id)
  Throws      : If input is not correct type
  Comments    : 

=cut

sub fetch_all_by_crRNA_id {
    my ( $self, $crRNA_id, ) = @_;
    my $where_clause = 'amp.crRNA_id = ?';
    my $primer_pairs = $self->_fetch( $where_clause, [ $crRNA_id ], );
    return $primer_pairs;
}

=method fetch_by_id

  Usage       : $primer_pair_adaptor->fetch_by_id( '1' );
  Purpose     : method to retrieve a primer pair using it's db id.
  Returns     : Crispr::PrimerPair
  Parameters  : Str (primer pair db id)
  Throws      : If input is not correct type
  Comments    : 

=cut

sub fetch_by_id {
    my ( $self, $primer_pair_id, ) = @_;
    my $where_clause = 'pp.primer_pair_id = ?';
    my $primer_pairs = $self->_fetch( $where_clause, [ $primer_pair_id ], );
    return $primer_pairs->[0];
}

=method fetch_by_plate_name_and_well

  Usage       : $primer_pair_adaptor->fetch_by_plate_name_and_well( 'CR_000001g', 'A01' );
  Purpose     : method to retrieve a primer pair using a plate name and well id
  Returns     : Crispr::PrimerPair
  Parameters  : Str (plate name)
                Str (well id)
  Throws      : 
  Comments    : returns undef if no primer pair object is returned form the database

=cut

sub fetch_by_plate_name_and_well {
    my ( $self, $plate_name, $well_id, ) = @_;
    my $primer_pairs = [];
    
    my $sql = <<"END_SQL";
SELECT pp.primer_pair_id, type, left_primer_id, right_primer_id,
pp.chr, pp.start, pp.end, pp.strand, pp.product_size,
p1.primer_id, p1.primer_sequence, p1.primer_chr, p1.primer_start, p1.primer_end,
p1.primer_strand, p1.primer_tail, p1.plate_id, p1.well_id
FROM primer_pair pp, primer p1, amplicon_to_crRNA amp, plate pl
WHERE pp.primer_pair_id = amp.primer_pair_id
AND pp.left_primer_id = p1.primer_id
AND pl.plate_id = p1.plate_id
END_SQL
    
    my $where_clause = 'pl.plate_name = ?';
    $sql .= 'AND pl.plate_name = ?';
    my $where_params = [ $plate_name ];
    
    if( $well_id ){
        $sql .= ' AND p1.well_id = ?';
        $where_clause .= ' AND p1.well_id = ?';
        push @{$where_params}, $well_id;
    }
    my $sth = $self->_prepare_sql( $sql, $where_clause, $where_params, );
    $sth->execute();
    
    my ( $primer_pair_id, $type, $left_primer_id, $right_primer_id,
        $chr, $start, $end, $strand, $product_size,
        $primer_id, $primer_sequence, $primer_chr, $primer_start, $primer_end,
        $primer_strand, $primer_tail, $plate_id );
    
    $sth->bind_columns( \( $primer_pair_id, $type,
        $left_primer_id, $right_primer_id,
        $chr, $start, $end, $strand, $product_size,
        $primer_id, $primer_sequence, $primer_chr, $primer_start, $primer_end,
        $primer_strand, $primer_tail, $plate_id, $well_id ) );
    
    while ( $sth->fetch ) {
        if( !exists $self->_primer_pair_cache->{ $primer_pair_id } ){
            my $primer_sequence = defined $primer_tail
                    ?   $primer_tail . $primer_sequence
                    :   $primer_sequence;
            my $primer_name = join(":", $primer_chr,
                                   join("-", $primer_start, $primer_end, ),
                                   $primer_strand, );
            
            my $well;
            if( defined $plate_id && defined $well_id ){
                my $plate = $self->plate_adaptor->fetch_empty_plate_by_id( $plate_id, );
                $well = Labware::Well->new(
                    position => $well_id,
                    plate => $plate,
                );
            }
            my $left_primer = Crispr::Primer->new(
                primer_id => $left_primer_id,
                sequence => $primer_sequence,
                primer_name => $primer_name,
                seq_region => $primer_chr,
                seq_region_strand => $primer_strand,
                seq_region_start => $primer_start,
                seq_region_end => $primer_end,
                well => $well,
            );
            my $right_primer = $self->primer_adaptor->fetch_by_id( $right_primer_id );
            my $pair_name = join(":", $chr, join("-", $start, $end, ), $strand, );
            
            my $primer_pair = Crispr::PrimerPair->new(
                primer_pair_id => $primer_pair_id,
                left_primer => $left_primer,
                right_primer => $right_primer,
                pair_name => $pair_name,
                product_size => $product_size,
                type => $type,
            );
            my $primer_pair_cache = $self->_primer_pair_cache;
            $primer_pair_cache->{ $primer_pair_id } = $primer_pair;
            $self->_set_primer_pair_cache( $primer_pair_cache );
            push @{$primer_pairs}, $primer_pair;
        }
        else{
            push @{$primer_pairs}, $self->_primer_pair_cache->{ $primer_pair_id };
        }
    }
    return $primer_pairs;
}

=method _fetch

  Usage       : $primer_pair_adaptor->_fetch( $where_clause, $where_params_array );
  Purpose     : internal method for fetching primer_pair from the database.
  Returns     : Crispr::PrimerPair
  Parameters  : Str - Where statement e.g. 'primer_pair_id = ?'
                ArrayRef - Where Parameters. One for each ? in where statement
  Throws      : 
  Comments    : 

=cut

sub _fetch {
    my ( $self, $where_clause, $where_parameters ) = @_;
    my $dbh = $self->connection->dbh();
    
    ## need to change query depending on whether driver is MySQL or SQLite
    #my ( $left_p_concat_statement, $right_p_concat_statement );
    #if( ref $self->connection->driver eq 'DBIx::Connector::Driver::mysql' ){
    #    $left_p_concat_statement = 'concat( p1.primer_tail, p1.primer_sequence )';
    #    $right_p_concat_statement = 'concat( p2.primer_tail, p2.primer_sequence )';
    #}else{
    #    $left_p_concat_statement = 'p1.primer_tail || p1.primer_sequence';
    #    $right_p_concat_statement = 'p2.primer_tail || p2.primer_sequence';
    #}
    
    my $sql = <<"END_SQL";
        SELECT
			pp.primer_pair_id, pp.type, pp.chr,
            pp.start, pp.end, pp.strand, pp.product_size,
            p1.primer_id, p1.primer_tail, p1.primer_sequence,
            p1.primer_chr, p1.primer_start, p1.primer_end, p1.primer_strand,
            p1.plate_id, p1.well_id,
            p2.primer_id, p2.primer_tail, p2.primer_sequence,
            p2.primer_chr, p2.primer_start, p2.primer_end, p2.primer_strand,
            p2.plate_id, p2.well_id
        FROM primer_pair pp, primer p1, primer p2, amplicon_to_crRNA amp
        WHERE left_primer_id = p1.primer_id AND right_primer_id = p2.primer_id
        AND pp.primer_pair_id = amp.primer_pair_id
END_SQL

    if ($where_clause) {
        $sql .= 'AND ' . $where_clause;
    }

    my $sth = $self->_prepare_sql( $sql, $where_clause, $where_parameters, );
    $sth->execute();

    my ( $primer_pair_id, $type, $chr, $start, $end, $strand, $product_size,
            $left_primer_id, $left_tail, $left_sequence, $left_primer_chr,
            $left_primer_start, $left_primer_end, $left_primer_strand,
            $left_primer_plate_id, $left_primer_well_id,
            $right_primer_id, $right_tail, $right_sequence, $right_primer_chr,
            $right_primer_start, $right_primer_end, $right_primer_strand,
            $right_primer_plate_id, $right_primer_well_id, );
    
    $sth->bind_columns( \( $primer_pair_id, $type, $chr, $start, $end, $strand, $product_size,
            $left_primer_id, $left_tail, $left_sequence, $left_primer_chr,
            $left_primer_start, $left_primer_end, $left_primer_strand,
            $left_primer_plate_id, $left_primer_well_id,
            $right_primer_id, $right_tail, $right_sequence, $right_primer_chr,
            $right_primer_start, $right_primer_end, $right_primer_strand,
            $right_primer_plate_id, $right_primer_well_id, ) );

    my @primer_pairs = ();
    while ( $sth->fetch ) {
        my $primer_pair;
        if( !exists $self->_primer_pair_cache->{ $primer_pair_id } ){
            $left_sequence = $left_tail ? $left_tail . $left_sequence
                : $left_sequence;
            my $left_well;
            if( defined $left_primer_plate_id && defined $left_primer_well_id ){
                my $plate = $self->plate_adaptor->fetch_empty_plate_by_id( $left_primer_plate_id, );
                $left_well = Labware::Well->new(
                    position => $left_primer_well_id,
                    plate => $plate,
                );
            }
            my $left_primer = Crispr::Primer->new(
                primer_id => $left_primer_id,
                sequence => $left_sequence,
                seq_region => $left_primer_chr,
                seq_region_start => $left_primer_start,
                seq_region_end => $left_primer_end,
                seq_region_strand => $left_primer_strand,
                well => $left_well,
            );
            
            $right_sequence = $right_tail ? $right_tail . $right_sequence
                : $right_sequence;
            my $right_well;
            if( defined $right_primer_plate_id && defined $right_primer_well_id ){
                my $plate = $self->plate_adaptor->fetch_empty_plate_by_id( $right_primer_plate_id, );
                $right_well = Labware::Well->new(
                    position => $right_primer_well_id,
                    plate => $plate,
                );
            }
            my $right_primer = Crispr::Primer->new(
                primer_id => $right_primer_id,
                sequence => $right_sequence,
                seq_region => $right_primer_chr,
                seq_region_start => $right_primer_start,
                seq_region_end => $right_primer_end,
                seq_region_strand => $right_primer_strand,
                well => $right_well,
            );
            
            my $pair_name = join(":", $chr, join("-", $start, $end, ), $strand, );
            $primer_pair = Crispr::PrimerPair->new(
                primer_pair_id => $primer_pair_id,
                type => $type,
                pair_name => $pair_name,
                left_primer => $left_primer,
                right_primer => $right_primer,
            );
            my $primer_pair_cache = $self->_primer_pair_cache;
            $primer_pair_cache->{ $primer_pair_id } = $primer_pair;
            $self->_set_primer_pair_cache( $primer_pair_cache );
        }
        else{
            $primer_pair = $self->_primer_pair_cache->{ $primer_pair_id };
        }
        
        push @primer_pairs, $primer_pair;
    }

    return \@primer_pairs;    
}

1;

