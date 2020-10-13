## no critic (RequireUseStrict, RequireUseWarnings, RequireTidyCode)
package Crispr::DB::crRNAAdaptor;

## use critic

# ABSTRACT: crRNAAdaptor - object for storing crRNA objects in and
# retrieving them from an SQL database.

use warnings;
use strict;
use namespace::autoclean;
use Moose;
use Crispr::Target;
use Crispr::crRNA;
use Carp qw( cluck confess );
use English qw( -no_match_vars );
use DateTime;
use Readonly;
use Scalar::Util qw(looks_like_number);

use Crispr::DB::TargetAdaptor;

extends 'Crispr::DB::BaseAdaptor';

=method new

  Usage       : my $crRNA_adaptor = Crispr::DB::crRNAAdaptor->new(
                    db_connection => $db_connection,
                );
  Purpose     : Constructor for creating crRNAAdaptor objects
  Returns     : Crispr::DB::crRNAAdaptor object
  Parameters  :     db_connection => $db_connection,
  Throws      : If parameters are not the correct type
  Comments    : It is not recommended to call Crispr::DB::crRNAAdaptor->new directly
                The recommended usage is to create a new Crispr::DB::DBAdaptor object
                and call get_adaptor( 'crRNA' );

=cut

# cache for crRNA objects from db
has '_crRNA_cache' => (
	is => 'ro',
	isa => 'HashRef',
    init_arg => undef,
    writer => '_set_crRNA_cache',
    default => sub { return {}; },
);

=method store

  Usage       : $crRNA = $crRNA_adaptor->store( $crRNA );
  Purpose     : Store a crispr RNA in the database
  Returns     : Crispr::crRNA object
  Parameters  : Crispr::crRNA object
  Throws      : If argument is not a crRNA object
                If there is an error during the execution of the SQL statements
                    In this case the transaction will be rolled back
  Comments    :

=cut

sub store {
    my ( $self, $input ) = @_;
    # make an Array of $crRNA and call store_crRNAs
    $self->store_crRNAs( [ $input ] );
    return 1;
}

=method store_crRNAs

  Usage       : $crRNA = $crRNA_adaptor->store_crRNAs( [ $crRNA1, $crRNA2, ] );
  Purpose     : Store a crispr RNA in the database
  Returns     : 1 on Success
  Parameters  : ArrayRef of either Crispr::crRNA objects
                            or Labware::Well objects containing Crispr::crRNA objects
  Throws      : If argument is not an ArrayRef
                If any of the objects inside the ArrayRef are not either crRNA or Well objects
                If there is an error during the execution of the SQL statements
                    In this case the transaction will be rolled back
  Comments    : Only adds rows to the crRNA table. Does not store associated info.
                Use other methods provided to add coding scores, off-targets,
                    restriction enzymes, construction oligos, expression constructs,
                    and primers.

=cut

sub store_crRNAs {
    ## Store crRNAs
    ##  DOES NOT STORE CONSTRUCTION OLIGOS OR EXPRESSION CONSTRUCTS OR PRIMERS  ##
    my ( $self, $input ) = @_;
    my $dbh = $self->connection->dbh();

    # check $crRNAs is a Arrayref of Crispr::crRNA objects
    if( !$input ){
        confess "Argument to store is empty. An input must be supplied in order to add oligos to the database!\n";
    }
    if( !ref $input || ref $input ne 'ARRAY' ){
        confess "The supplied argument is not an ArrayRef!\n";
    }
    else{
        # check if $input is either a Labware::Well input or a Crispr::Primer one
        foreach my $object ( @{$input} ){
            if( !ref $object ||
               !($object->isa('Labware::Well') || $object->isa('Crispr::crRNA') ) ){
                confess join(q{ },
                    'The supplied input must be either a Labware::Well input',
                    'or a Crispr::crRNA input, not', ref $object, ), "!\n";
            }
        }
    }

    my ( @crisprs, @plate_ids, @well_ids, );
    foreach my $object ( @{$input} ){
        if( $object->isa('Labware::Well') ){
            my $crRNA = $object->contents;
            if( !$crRNA ){
                confess join(q{ },
                    'The well is empty!',
                    'A Crispr::crRNA input must be supplied to add to the database',
                ), "!\n";
            }
            else{
                # check $crRNA is a Crispr::crRNA input
                if( !ref $crRNA || !$crRNA->isa('Crispr::crRNA') ){
                    confess join(q{ },
                        'The object in the supplied Labware::Well object must be a Crispr::crRNA object, not',
                        ref $crRNA,
                    ), "!\n";
                }
            }
            # check crispr has a target
            if( !defined $crRNA->target ){
                confess "Each Crispr::crRNA object must have an associated Target to be able to add it to the database.\n";
            }

            push @crisprs, $crRNA;
            # check plate exists - check_entry_exists_in_db inherited from DBAttributes.
            my ( $plate_id, $well_id, );
            my $check_plate_st = 'select count(*) from plate where plate_name = ?';
            if( !$self->check_entry_exists_in_db( $check_plate_st, [ $object->plate->plate_name ] ) ){
                # add plate to database
                $self->plate_adaptor->store( $object->plate );
            }
            if( !$object->plate->plate_id ){
                # fetch plate id from db
                $plate_id = $self->plate_adaptor->get_plate_id_from_name( $object->plate->plate_name );
            }
            else{
                $plate_id = $object->plate->plate_id;
            }
            push @plate_ids, $plate_id;
            push @well_ids, $object->position;
        }
        if( $object->isa('Crispr::crRNA') ){
            push @crisprs, $object;
            # check crispr has a target
            if( !defined $object->target ){
                confess "Each Crispr::crRNA object must have an associated Target to be able to add it to the database.\n";
            }
        }
    }

    $self->connection->txn(  fixup => sub {
        foreach my $crRNA ( @crisprs ){
            my $plate_id = shift @plate_ids;
            my $well_id = shift @well_ids;

            # insert values into table crRNA
            my $statement = "insert into crRNA values( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? );";

            # check target exists - check_entry_exists_in_db inherited from BaseAdaptor.
            my ( $check_target_st, $target_params );
            if( $crRNA->target->target_id ){
                $check_target_st = 'select count(*) from target where target_id = ?;';
                $target_params = [ $crRNA->target->target_id ];
            }
            elsif( $crRNA->target->target_name && $crRNA->target->requestor ){
                $check_target_st = 'select count(*) from target where target_name = ? and requestor = ?;';
                $target_params = [ $crRNA->target->target_name, $crRNA->target->requestor ];
            }

            if( !$self->check_entry_exists_in_db( $check_target_st, $target_params ) ){
                # try and store it in the db
                $self->target_adaptor->store( $crRNA->target );
            }
            # need target_id - if have target_name but no id, get id from db.
            if( !$crRNA->target_id && $crRNA->target_name ){
                $crRNA->target( $self->target_adaptor->fetch_by_name_and_requestor( $crRNA->target_name, $crRNA->target->requestor ) );
            }

            my $sth = $dbh->prepare($statement);
            my $off_target_score = defined $crRNA->off_target_hits ? $crRNA->off_target_score : undef;
            my $coding_score = defined $crRNA->coding_score ?
                $crRNA->coding_score : undef;
            my $status_id = $self->_fetch_status_id_from_status( $crRNA->status );
            $sth->execute($crRNA->crRNA_id, $crRNA->name,
                $crRNA->chr, $crRNA->start, $crRNA->end, $crRNA->strand,
                $crRNA->sequence, $crRNA->five_prime_Gs,
                $crRNA->score, $off_target_score,
                $coding_score,
                $crRNA->target_id, $plate_id, $well_id,
                $status_id, $crRNA->status_changed,
            );
            
            my $last_id;
            $last_id = $dbh->last_insert_id( 'information_schema', $self->dbname(), 'crRNA', 'crRNA_id' );
            $crRNA->crRNA_id( $last_id );
            $sth->finish();

            $self->update_status( $crRNA->target );

        }
    } );

    return 1;
}

=method store_restriction_enzyme_info

  Usage       : $crRNA = $crRNA_adaptor->store_restriction_enzyme_info( $crRNA );
  Purpose     : Store the information about restriction enzymes for a crispr RNA in the database
  Returns     : 1 on Success
  Parameters  : Crispr::crRNA object
  Throws      : If argument is not a Crispr::crRNA object
  Comments    : Enzymes that don't exist in the database will be added

=cut

sub store_restriction_enzyme_info {
    my ( $self, $crRNA, $primer_pair ) = @_;
    my $dbh = $self->connection->dbh();

    # check inputs
    if( !$crRNA ){
        confess "A crRNA object is required for adding enzyme info to the database.\n";
    }
    elsif( !ref $crRNA || !$crRNA->isa('Crispr::crRNA' ) ){
        confess join(q{ },
            "The supplied object should be a Crispr::crRNA object, not",
            ref $crRNA, ), ".\n";
    }
    elsif( !$crRNA->unique_restriction_sites ){
        confess "The Crispr::crRNA object must contain an EnzymeInfo object!\n";
    }

    if( !$primer_pair ){
        confess "A primer pair object is required for adding enzyme info to the database.\n";
    }
    elsif( !ref $primer_pair || !$primer_pair->isa('Crispr::PrimerPair' ) ){
        confess join(q{ },
            "The supplied object should be a Crispr::PrimerPair object, not",
            ref $primer_pair, ), ".\n";
    }

    # get enzyme info
    my $enzyme_info = $crRNA->unique_restriction_sites;

    # will need to check that enzymes already exist in the db
    my $check_re_st = "select count(*) from enzyme where name = ?;";
    # insert values into table restriction_enzymes
    my $statement = <<"END_ST";
insert into restriction_enzymes values( ?, ?,
(select enzyme_id from enzyme where name = ?), ?, ? );
END_ST

    my $add_enzyme_st = "insert into enzyme values(?, ?, ?);";

    $self->connection->txn(  fixup => sub {
        my $sth = $dbh->prepare($statement);
        foreach my $enzyme ( $enzyme_info->uniq_in_both->each_enzyme ){
            if( !$self->check_entry_exists_in_db( $check_re_st, [ $enzyme->name ] ) ){
                # complain
                warn q{Couldn't find enzyme:}, $enzyme->name, " in the database!\nAdding...";
                my $add_sth = $dbh->prepare($add_enzyme_st);
                $add_sth->execute(
                    undef,
                    $enzyme->name,
                    $enzyme->site,
                );
                $add_sth->finish();
            }

            # get fragments sizes. returns an array of sizes in bp sorted from largest to smallest
            my @fragments = $enzyme_info->amplicon_analysis->sizes($enzyme, 0, 1);
            $sth->execute(
                $primer_pair->primer_pair_id,
                $crRNA->crRNA_id,
                $enzyme->name,
                $enzyme_info->proximity_to_cut_site( $enzyme ),
                join(',', @fragments ),
            );
        }
        $sth->finish();
    } );

    return 1;
}

=method store_coding_scores

  Usage       : $crRNA = $crRNA_adaptor->store_coding_scores( $crRNA );
  Purpose     : Store the coding scores for a crispr RNA in the database
  Returns     : 1 on Success
  Parameters  : Crispr::crRNA object
  Throws      : If argument is not a Crispr::crRNA object
  Comments    :

=cut

sub store_coding_scores {
    my ( $self, $crRNA ) = @_;
    my $dbh = $self->connection->dbh();

    # insert values into table coding_scores
    my $statement = "insert into coding_scores values( ?, ?, ? );";

    $self->connection->txn(  fixup => sub {
        my $sth = $dbh->prepare($statement);
        foreach my $transcript ( sort keys %{$crRNA->coding_scores} ){
            $sth->execute(
                $crRNA->crRNA_id,
                $transcript,
                $crRNA->coding_scores->{$transcript},
            );
        }
        $sth->finish();
    } );

    return 1;
}

=method store_off_target_info

  Usage       : $crRNA = $crRNA_adaptor->store_off_target_info( $crRNA );
  Purpose     : Store the off_target scores for a crispr RNA in the database
  Returns     : 1 on Success
  Parameters  : Crispr::crRNA object
  Throws      : If argument is not a Crispr::crRNA object
  Comments    :

=cut

sub store_off_target_info {
    my ( $self, $crRNA ) = @_;
    my $dbh = $self->connection->dbh();

    # check object is a crRNA and that the OffTarget attribute is defined
    if( !$crRNA ){
        confess "A crRNA object must be supplied to add off-targets to the database!\n";
    }
    else{
        if( !ref $crRNA || !$crRNA->isa('Crispr::crRNA') ){
            confess "The supplied arguments must be a Crispr::crRNA object, not a ",
                ref $crRNA || 'String', "\n";
        }
        if( !defined $crRNA->off_target_hits ){
            warn "There is no off-target info for crRNA, ", $crRNA->name, "\n";
            return;
        }
        if( $crRNA->off_target_hits->number_hits == 0 ){
            return;
        }
    }

    # need to check that the crRNA exists in the db
    if( !$crRNA->crRNA_id ){
        confess "Supplied Crispr::crRNA does not have a database id.\n";
    }
    my $check_statement = 'select count(*) from crRNA where crRNA_id = ?;';
    if( !$self->check_entry_exists_in_db( $check_statement, [ $crRNA->crRNA_id ] ) ){
        confess "crRNA, ", $crRNA->name, "does not exists in the database\n";
    }

    # insert values into table off_target_info
    my $statement = "insert into off_target_info values( ?, ?, ?, ? );";
    ## check warnings TO DO reinstate this comply with sqlite
    #my $warning_st = "show warnings;";

    $self->connection->txn(  fixup => sub {
        my $sth = $dbh->prepare($statement);
        foreach my $off_target ( $crRNA->off_target_hits->all_off_targets ){
            $sth->execute(
                $crRNA->crRNA_id,
                $off_target->position,
                $off_target->mismatches,
                $off_target->annotation,
            );
        }

    } );
    return 1;
}

=method store_expression_construct_info

  Usage       : $crRNA = $crRNA_adaptor->store_expression_construct_info( $well );
  Purpose     : Store the information about the expression construct for a crispr RNA in the database
  Returns     : 1 on Success
  Parameters  : Labware::Well object containing a Crispr::crRNA object
  Throws      : If argument is not a Crispr::crRNA object
  Comments    :

=cut

sub store_expression_construct_info {
    my ( $self, $well ) = @_;
    my $dbh = $self->connection->dbh();

    my $crRNA = $well->contents;
    if( !$crRNA ){
        confess "A crRNA object must be supplied to add to the database!\n";
    }
    else{
        # check $crRNA is a Crispr::crRNA object
        if( !ref $crRNA || !$crRNA->isa('Crispr::crRNA') ){
            confess "The supplied object must be a Crispr::crRNA object, not ", ref $crRNA, "!\n";
        }
    }
    if( !$well ){
        confess "A Labware::Well object must be supplied in order to add oligos to the database!\n";
    }
    else{
        # check $well is a Labware::Well object
        if( !ref $well || !$well->isa('Labware::Well') ){
            confess "The supplied object must be a Labware::Well object, not ", ref $well, "!\n";
        }
    }

    # check plate exists - check_entry_exists_in_db inherited from BaseAdaptor.
    my $plate_id;
    my $check_plate_st = 'select count(*) from plate where plate_name = ?';
    if( !$self->check_entry_exists_in_db( $check_plate_st, [ $well->plate->plate_name ] ) ){
        # add plate to database
        $self->plate_adaptor->store( $well->plate );
    }

    if( !$well->plate->plate_id ){
        # fetch plate id from db
        $plate_id = $self->plate_adaptor->get_plate_id_from_name( $well->plate->plate_name );
    }
    else{
        $plate_id = $well->plate->plate_id;
    }

    my $backbone_id = $self->check_plasmid_backbone_exists( $dbh, $crRNA );

    my $construct_st = "insert into expression_construct values( ?, ?, ?, ?, ?, ? );";

    $self->connection->txn(  fixup => sub {
        my $sth = $dbh->prepare($construct_st);
        $sth->execute(
            $crRNA->crRNA_id,
            $plate_id,
            $well->position,
            undef,
            undef,
            $backbone_id,
        );
        $sth->finish();
    } );

    return 1;
}

=method store_construction_oligos

  Usage       : $crRNA = $crRNA_adaptor->store_construction_oligos( $well );
  Purpose     : Store the information about the oligos used to clone the expression construct for a crispr RNA in the database
  Returns     : 1 on Success
  Parameters  : Labware::Well object containing a Crispr::crRNA object
  Throws      : If argument is not a Crispr::crRNA object
  Comments    :

=cut

sub store_construction_oligos {
    my ( $self, $well, $oligo_type ) = @_;
    my $dbh = $self->connection->dbh();

    my $crRNA = $well->contents;
    if( !$crRNA ){
        confess "A crRNA object must be supplied to add to the database!\n";
    }
    else{
        #check $crRNA is a Crispr::crRNA object
        if( !ref $crRNA || !$crRNA->isa('Crispr::crRNA') ){
            confess "The supplied object must be a Crispr::crRNA object, not a ", ref $crRNA, " one.\n";
        }
    }
    if( !$well ){
        confess "A Labware::Well object must be supplied in order to add oligos to the database!\n";
    }
    else{
        # check $well is a Labware::Well object
        if( !ref $well || ( ref $well && !$well->isa('Labware::Well') ) ){
            confess "The supplied object must be a Labware::Well object, not a ", ref $well, "one.\n";
        }
    }

    my ( $oligo1, $oligo2, $backbone_id );
    if( $oligo_type eq 'cloning_oligos' ){
        $oligo1 = $crRNA->forward_oligo;
        $oligo2 = $crRNA->reverse_oligo;
        $backbone_id = $self->check_plasmid_backbone_exists( $dbh, $crRNA );
    }
    elsif( $oligo_type eq 't7_hairpin_oligos' ){
        $oligo1 = $crRNA->t7_hairpin_oligo;
    }
    elsif( $oligo_type eq 't7_fill-in_oligos' ){
        $oligo1 = $crRNA->t7_fillin_oligo;
    }
    else{
        confess "store_construction_oligos: Couldn't understand oligo type - ",
            $oligo_type, "\n";
    }

    # check plate exists - check_entry_exists_in_db inherited from BaseAdaptor.
    my $plate_id;
    my $check_plate_st = 'select count(*) from plate where plate_name = ?';
    if( !$self->check_entry_exists_in_db( $check_plate_st, [ $well->plate->plate_name ] ) ){
        # add plate to database
        $self->plate_adaptor->store( $well->plate );
    }
    if( !$well->plate->plate_id ){
        # fetch plate id from db
        $plate_id = $self->plate_adaptor->get_plate_id_from_name( $well->plate->plate_name );
    }
    else{
        $plate_id = $well->plate->plate_id;
    }

    my $insert_oligos_st = "insert into construction_oligos values( ?, ?, ?, ?, ?, ? );";

    $self->connection->txn(  fixup => sub {
        my $sth = $dbh->prepare($insert_oligos_st);
        $sth->execute(
            $crRNA->crRNA_id,
            $oligo1,
            $oligo2,
            $backbone_id,
            $plate_id,
            $well->position,
        );
        $sth->finish();
    } );

    return 1;
}

=method check_plasmid_backbone_exists

  Usage       : $crRNA = $crRNA_adaptor->store_construction_oligos( $well );
  Purpose     : Store the information about the oligos used to clone the expression construct for a crispr RNA in the database
  Returns     : 1 on Success
  Parameters  : Labware::Well object containing a Crispr::crRNA object
  Throws      : If argument is not a Crispr::crRNA object
  Comments    :

=cut

sub check_plasmid_backbone_exists {
    my ( $self, $dbh, $crRNA ) = @_;
    # check plasmid backbone exists in plasmid_backbone table
    my $check_backbone_st = "select plasmid_backbone_id from plasmid_backbone where plasmid_backbone = ?;";
    my $sth = $dbh->prepare( $check_backbone_st );
    $sth->execute( $crRNA->plasmid_backbone );
    my $backbone_id;
    while( my @fields = $sth->fetchrow_array ){
        $backbone_id = $fields[0];
    }
    # if it doesn't add and record the backbone id
    if( !$backbone_id ){
        warn join(q{ }, 'Plasmid backbone', $crRNA->plasmid_backbone, "doesn't exist in the database - Adding...\n", );
        # add plasmid backbone to db
        my $add_backbone_st = "insert into plasmid_backbone values( ?, ? );";
        my $sth = $dbh->prepare($add_backbone_st);
        $sth->execute( undef, $crRNA->plasmid_backbone );
        $backbone_id = $dbh->last_insert_id( 'information_schema', $self->dbname(), 'plasmid_backbone', 'plasmid_backbone_id' );
        $sth->finish();
    }
    return $backbone_id;
}


=method aggregate_sequencing_results

  Usage       : $ok = $crRNA_adaptor->aggregate_sequencing_results( $crRNA );
  Purpose     : return the sequencing results for a list of crispr ids
  Returns     : HASHREF
  Parameters  : ARRAYREF of Crispr::crRNA objects
  Throws      : If crRNA does not exist in the db
                If argument is not a Crispr::crRNA object
  Comments    : None

=cut

sub aggregate_sequencing_results {
    my ( $self, $crRNAs, ) = @_;
    my $dbh = $self->connection->dbh();
    
    my $sql = <<END_ST;
SELECT crRNA_id, injection_id, type, SUM(pass) as num_passes
FROM sample s, sequencing_results seq WHERE s.sample_id = seq.sample_id
END_ST

    my $where_clause = 'AND crRNA_id IN (' . join(q{,}, ('?') x scalar @{$crRNAs} ) . ') GROUP BY crRNA_id, type';
    $sql .= $where_clause;
    
    my $where_parameters = [ map { $_->crRNA_id } @{$crRNAs} ];
    
    my $sth = $self->_prepare_sql( $sql, $where_clause, $where_parameters, );
    $sth->execute();

    my ( $crRNA_id, $injection_id, $type, $num_passes, );

    $sth->bind_columns( \( $crRNA_id, $injection_id, $type, $num_passes, ) );
    
    my %results = ();
    while ( $sth->fetch ) {
        $results{ $crRNA_id }{$type} = $num_passes,
    }
    
    return( \%results );
}

=method fetch_by_id

    Usage       : $crRNAs = $crRNA_adaptor->fetch_by_id( $crRNA_id );
    Purpose     : Fetch a crRNA given a crRNA id
    Returns     : Crispr::crRNA object
    Parameters  : crispr-db crRNA id
    Throws      : If no rows are returned from the database or if too many rows are returned
    Comments    : None

=cut

sub fetch_by_id {
    my ( $self, $id ) = @_;

    my $crRNA = $self->_fetch( 'crRNA_id = ?', [ $id ] )->[0];
    if( !$crRNA ){
        confess "Couldn't retrieve crRNA, $id, from database.\n";
    }
    return $crRNA;
}

=method fetch_by_ids

    Usage       : $crRNAs = $crRNA_adaptor->fetch_by_ids( \@crRNA_ids );
    Purpose     : Fetch a list of crRNAs given a list of db ids
    Returns     : Arrayref of Crispr::Target objects
    Parameters  : Arrayref of talen-db crRNA ids
    Throws      : If no rows are returned from the database
    Comments    : None

=cut

sub fetch_by_ids {
    my ( $self, $ids ) = @_;
    my @crRNAs;

    foreach my $id ( @{$ids} ){
        my $crRNA = $self->fetch_by_id( $id );
        push @crRNAs, $crRNA;
    }

    return \@crRNAs;
}

=method fetch_all_by_name

    Usage       : $crRNAs = $crRNA_adaptor->fetch_all_by_name( $crRNA_name, );
    Purpose     : Fetch crRNAs given a crRNA name
    Returns     : ArrayRef of Crispr::crRNA objects
    Parameters  : crispr-db crRNA name
    Throws      : If no rows are returned
    Comments    : None

=cut

sub fetch_all_by_name {
    my ( $self, $name, ) = @_;

    my $crRNAs = $self->_fetch( 'crRNA_name = ?', [ $name, ] );
    if( !$crRNAs ){
        confess "Couldn't retrieve crRNA, $name, from database.\n";
    }
    return $crRNAs;
}

=method fetch_by_name_and_target

    Usage       : $crRNAs = $crRNA_adaptor->fetch_by_name_and_target( $crRNA_name, $target );
    Purpose     : Fetch a crRNA given a crRNA name and a Crispr::Target object
    Returns     : Crispr::Target object
    Parameters  : crispr-db crRNA name
    Throws      : If no rows are returned from the database or if too many rows are returned
    Comments    : None

=cut

sub fetch_by_name_and_target {
    my ( $self, $name, $target ) = @_;

    my $statement = <<END_ST;
select * from target t, crRNA c where
c.crRNA_name = ? and t.target_id = ? and c.target_id = t.target_id;
END_ST
    my $params = [ $name, $target->target_id, ];
    my $results;
    my $crRNA;
    eval {
        $results = $self->fetch_rows_expecting_single_row( $statement, $params, );
    };
    if( $EVAL_ERROR ){
        $self->_db_error_handling( $EVAL_ERROR, $statement, $params, );
    }
    else{
        my @crRNA_fields = @{ $results }[15..30];
        $crRNA = $self->_make_new_crRNA_from_db( \@crRNA_fields, );
        my @target_fields = @{ $results }[0..14];
        $crRNA->target( $self->target_adaptor->_make_new_target_from_db( \@target_fields ) );
    }

    return $crRNA;
}

=method fetch_by_names_and_targets

    Usage       : $crRNAs = $crRNA_adaptor->fetch_by_names( \@crRNA_names_and_targets,  );
    Purpose     : Fetch a list of crRNAs given a list of db crRNA names with Crispr::Target objects
    Returns     : ArrayRef of Crispr::crRNA objects
    Parameters  : Arrayref of ArrayRefs ( [ [ crRNA_name , Crispr::Target ] ] )
    Throws      : If no rows are returned from the database
    Comments    : None

=cut

sub fetch_by_names_and_targets {
    my ( $self, $info ) = @_;
    my $dbh = $self->connection->dbh();
    my @crRNAs;

    foreach my $name_and_target ( @{$info} ){
        push @crRNAs, $self->fetch_by_name( @{$name_and_target} );
    }

    return \@crRNAs;
}

=method fetch_all_by_target

    Usage       : $crRNAs = $crRNA_adaptor->{fetch_all_by_t}arget( $target );
    Purpose     : Fetch a list of crRNAs given a Crispr::Target objects
    Returns     : Arrayref of Crispr::crRNA objects
    Parameters  : Crispr::Target
    Throws      : If no rows are returned from the database
    Comments    : None

=cut

sub fetch_all_by_target {
    my ( $self, $target, ) = @_;

    my $crRNAs = $self->_fetch( 'target_id = ?', [ $target->target_id, ] );
    if( !$crRNAs ){
        confess "Couldn't retrieve crRNAs for target, ", $target->name, " from database.\n";
    }
    return $crRNAs;
}

=method fetch_all_by_targets

    Usage       : $crRNAs = $crRNA_adaptor->fetch_all_by_targets( $targets );
    Purpose     : Fetch a list of crRNAs given Crispr::Target objects
    Returns     : Arrayref of Crispr::crRNA objects
    Parameters  : Crispr::Target
    Throws      : If no rows are returned from the database
    Comments    : None

=cut

sub fetch_all_by_targets {
    my ( $self, $targets, ) = @_;

    my @crRNAs;
    foreach my $target ( @{$targets} ){
        my $crRNAs = $self->_fetch( 'target_id = ?', [ $target->target_id, ] );
        if( @{$crRNAs} ){
            push @crRNAs, @{$crRNAs};
        }
    }
    return \@crRNAs;
}

=method fetch_by_plate_num_and_well

  Usage       : $crRNAs = $crRNA_adaptor->fetch_by_plate_num_and_well( $plate_num, $well_id );
  Purpose     : Fetch a crRNA given a plate number and well
  Returns     : Crispr::crRNA
  Parameters  : Str     (Plate number)
                Str     (well id)
  Throws      : If no rows are returned from the database
  Comments    : None

=cut

sub fetch_by_plate_num_and_well {
    my ( $self, $plate_num, $well_id ) = @_;

    my @crRNAs;
    # check that plate is a number
    my $plate_name;
    if( looks_like_number( $plate_num ) ){
        $plate_name = sprintf("CR_%06d-", $plate_num);
    }
    elsif( $plate_num =~ /\A
          CR_0{0,5} # start with CR_ and then 0-5 zeros
          \d+       # then 1 or more digits
          [a-z]     # then a lowercase letter
          \z/xms ){
        $plate_name = $plate_num;
    }
    else{
        confess "Supplied plate number, $plate_num, does not look like a number!\n";
    }

    my $db_statement = <<END_ST;
SELECT * FROM crRNA cr, plate pl WHERE plate_name = ? AND
cr.plate_id = pl.plate_id
END_ST

    my $params;
    if( $well_id ){
        $db_statement .= 'AND well_id = ?';
        $params = [ $plate_name, $well_id ];
    }
    else{
        $params = [ $plate_name ];
    }
    my $results;
    eval {
        $results = $self->fetch_rows_for_generic_select_statement(
            $db_statement,
            $params,
        );
    };
    if( $EVAL_ERROR ){
        $self->_db_error_handling( $EVAL_ERROR, $db_statement, $params, );
    }
    else{
        foreach my $result ( @{$results} ){
            my $crRNA = $self->_make_new_crRNA_from_db( [ @{$result}[ 0..15 ] ] );
            push @crRNAs, $crRNA;
        }
    }

    if( $well_id ){
        if( scalar @crRNAs > 1 ){
            die "Got more than one crispr for a single well!";
        }
        else{
            return $crRNAs[0];
        }
    }
    else{
        return \@crRNAs;
    }
}

=method fetch_all_by_primer_pair

    Usage       : $crRNAs = $crRNA_adaptor->fetch_all_by_primer_pair( $primer_pair );
    Purpose     : Fetch a list of crRNAs given a Crispr::PrimerPair object
    Returns     : Arrayref of Crispr::crRNA objects
    Parameters  : Crispr::PrimerPair
    Throws      : If PrimerPair primer_pair_id attribute is not defined
                    If no rows are returned from the database
    Comments    : None

=cut

sub fetch_all_by_primer_pair {
    my ( $self, $primer_pair, ) = @_;
    my @crRNAs;

    if( !defined $primer_pair->primer_pair_id ){
        die join(q{ }, "primer_pair_id attribute is not defined for primer pair,",
            $primer_pair->pair_name, "; Cannot retrieve crRNAs from database."), "\n";
    }
    my $where_clause = 'primer_pair_id = ? and amp.crRNA_id = cr.crRNA_id;';
    my $where_parameters = [ $primer_pair->primer_pair_id ];

    my $sql = <<END_ST;
    SELECT cr.crRNA_id, crRNA_name, chr, start, end, strand, sequence,
    num_five_prime_Gs, score, off_target_score, coding_score, target_id,
    plate_id, well_id, status_id, status_changed
    FROM crRNA cr, amplicon_to_crRNA amp
END_ST

    if ($where_clause) {
        $sql .= 'WHERE ' . $where_clause;
    }

    my $sth = $self->_prepare_sql( $sql, $where_clause, $where_parameters, );
    $sth->execute();

    my ( $crRNA_id, $crRNA_name, $chr, $start, $end, $strand, $sequence,
        $num_five_prime_Gs, $score, $off_target_score, $coding_score,
        $target_id, $plate_id, $well_id, $status_id, $status_changed, );

    $sth->bind_columns( \( $crRNA_id, $crRNA_name, $chr, $start, $end, $strand, $sequence,
        $num_five_prime_Gs, $score, $off_target_score, $coding_score,
        $target_id, $plate_id, $well_id, $status_id, $status_changed, ) );

    while ( $sth->fetch ) {
        if( !exists $self->_crRNA_cache->{ $crRNA_id } ){
            my $crRNA = $self->_make_new_crRNA_from_db(
                [ $crRNA_id, $crRNA_name, $chr, $start, $end, $strand,
                $sequence, $num_five_prime_Gs, $score, $off_target_score, $coding_score,
                $target_id, $plate_id, $well_id, $status_id, $status_changed, ] );
            push @crRNAs, $crRNA;
            my $crRNA_cache = $self->_crRNA_cache;
            $crRNA_cache->{ $crRNA_id } = $crRNA;
            $self->_set_crRNA_cache( $crRNA_cache );
        }
        else{
            push @crRNAs, $self->_crRNA_cache->{ $crRNA_id };
        }
    }

    return \@crRNAs;
}

=method fetch_all_by_status

  Usage       : $target = $target_adaptor->fetch_all_by_status( 'gene' );
  Purpose     : Fetch all targets in the db for a given gene name
  Returns     : Crispr::Target object
  Parameters  : Gene Name (Str)
  Throws      : If no rows are returned from the database
  Comments    : None

=cut

sub fetch_all_by_status {
    my ( $self, $status ) = @_;
    my $dbh = $self->connection->dbh();

    my $sql = <<'END_SQL';
        SELECT
            crRNA_id, crRNA_name, chr, start, end, strand, sequence,
            num_five_prime_Gs, score, off_target_score, coding_score,
            target_id, plate_id, well_id, cr.status_id, status_changed
        FROM crRNA cr, status st
        WHERE cr.status_id = st.status_id
        AND st.status = ?
END_SQL

    my $where_clause = 'AND st.status = ?';
    my $sth = $self->_prepare_sql( $sql, $where_clause, [ $status ] );
    $sth->execute();

    my ( $crRNA_id, $crRNA_name, $chr, $start, $end, $strand, $sequence,
            $num_five_prime_Gs, $score, $off_target_score, $coding_score,
            $target_id, $plate_id, $well_id, $status_id, $status_changed
    );

    $sth->bind_columns( \( $crRNA_id, $crRNA_name, $chr, $start, $end, $strand,
        $sequence, $num_five_prime_Gs, $score, $off_target_score, $coding_score,
        $target_id, $plate_id, $well_id, $status_id, $status_changed, ) );

    my @crRNAs = ();
    while ( $sth->fetch ) {
        my $crRNA;
        if( !exists $self->_crRNA_cache->{ $crRNA_id } ){
            # fetch target by target_id
            my $target = $self->target_adaptor->fetch_by_id( $target_id );
            $crRNA = Crispr::crRNA->new(
                crRNA_id => $crRNA_id,
                target => $target,
                chr => $chr,
                start => $start,
                end => $end,
                strand => $strand,
                sequence => $sequence,
                five_prime_Gs => $num_five_prime_Gs,
                crRNA_adaptor => $self,
                status => $status,
                status_changed => $status_changed,
            );
            my $crRNA_cache = $self->_crRNA_cache;
            $crRNA_cache->{ $crRNA_id } = $crRNA;
            $self->_set_crRNA_cache( $crRNA_cache );
        }
        else{
            $crRNA = $self->_crRNA_cache->{ $crRNA_id };
        }

        push @crRNAs, $crRNA;
    }

    return \@crRNAs;
}

# =method _fetch
#
#   Usage       : $crRNAs = $crRNA_adaptor->_fetch( $where_clause, $where_parameters );
#   Purpose     : Fetch crRNA objects from the database with arbitrary parameters
#   Returns     : ArrayRef of Crispr::crRNA objects
#   Parameters  : where_clause => Str (SQL where clause)
#                  where_parameters => ArrayRef of parameters to bind to sql statement
#   Throws      : If no rows are returned from the database
#   Comments    : None
#
# =cut

sub _fetch {
    my ( $self, $where_clause, $where_parameters ) = @_;
    my $dbh = $self->connection->dbh();

    my $sql = <<'END_SQL';
        SELECT
        crRNA_id, crRNA_name, chr, start, end, strand, sequence,
        num_five_prime_Gs, score, off_target_score, coding_score,
        target_id, plate_id, well_id, status_id, status_changed
        FROM crRNA
END_SQL

    if ($where_clause) {
        $sql .= 'WHERE ' . $where_clause;
    }

    my $sth = $self->_prepare_sql( $sql, $where_clause, $where_parameters, );
    $sth->execute();

    my ( $crRNA_id, $crRNA_name, $chr, $start, $end, $strand, $sequence,
            $num_five_prime_Gs, $score, $off_target_score, $coding_score,
            $target_id, $plate_id, $well_id, $status_id, $status_changed
    );

    $sth->bind_columns( \( $crRNA_id, $crRNA_name, $chr, $start, $end, $strand,
        $sequence, $num_five_prime_Gs, $score, $off_target_score, $coding_score,
        $target_id, $plate_id, $well_id, $status_id, $status_changed, ) );

    my @crRNAs = ();
    while ( $sth->fetch ) {
        my $status = $self->_fetch_status_from_id( $status_id );
        my $crRNA;
        if( !exists $self->_crRNA_cache->{ $crRNA_id } ){
            # fetch target by target_id
            my $target = $self->target_adaptor->fetch_by_id( $target_id );
            # make well if plate_id and well_id are defined
            my $well;
            if( defined $plate_id && defined $well_id ){
                my $plate = $self->plate_adaptor->fetch_empty_plate_by_id( $plate_id, );
                $well = Labware::Well->new(
                    position => $well_id,
                    plate => $plate,
                );
            }
            $crRNA = Crispr::crRNA->new(
                crRNA_id => $crRNA_id,
                target => $target,
                chr => $chr,
                start => $start,
                end => $end,
                strand => $strand,
                sequence => $sequence,
                five_prime_Gs => $num_five_prime_Gs,
                crRNA_adaptor => $self,
                status => $status,
                status_changed => $status_changed,
                well => $well,
            );
            my $crRNA_cache = $self->_crRNA_cache;
            $crRNA_cache->{ $crRNA_id } = $crRNA;
            $self->_set_crRNA_cache( $crRNA_cache );
        }
        else{
            $crRNA = $self->_crRNA_cache->{ $crRNA_id };
        }

        push @crRNAs, $crRNA;
    }

    return \@crRNAs;
}

=method _make_new_crRNA_from_db

  Usage       : $crRNAs = $crRNA_adaptor->_make_new_crRNA_from_db( $fields );
  Purpose     : Internal method to create a Crispr::crRNA object from a row returned from the database
  Returns     : Crispr::crRNA
  Parameters  : ArrayRef    (Database row)
  Throws      : If no rows are returned from the database
  Comments    : Expects the fields to be in this order:
                crRNA_id, crRNA_name, chr, start, end, strand, sequence,
                num_five_prime_Gs, score, off_target_score, coding_score,
                target_id, plate_id, well_id, status_id, status_changed

=cut

sub _make_new_crRNA_from_db {
    my ( $self, $fields ) = @_;
    my $crRNA;
    
    my $status = $self->_fetch_status_from_id( $fields->[14] );
    
    # make well if plate_id and well_id are defined
    my $well;
    if( defined $fields->[12] && defined $fields->[13] ){
        my $plate = $self->plate_adaptor->fetch_empty_plate_by_id( $fields->[12], );
        $well = Labware::Well->new(
            position => $fields->[13],
            plate => $plate,
        );
    }

    my %args = (
        crRNA_id => $fields->[0],
        name => $fields->[1],
        start => $fields->[3],
        end => $fields->[4],
        strand => $fields->[5],
        sequence => $fields->[6],
        five_prime_Gs => $fields->[7],
        status => $status,
        status_changed => $fields->[15],
        well => $well,
    );
    $args{ 'chr' } = $fields->[2] if( defined $fields->[2] );

    $crRNA = Crispr::crRNA->new( %args );
    $crRNA->target( $self->target_adaptor->fetch_by_crRNA($crRNA) );
    $crRNA->crRNA_adaptor( $self );

    return $crRNA;
}

#sub fetch_primer_pairs {
#    my ( $self, $crRNA ) = @_;
#    my $dbh = $self->connection->dbh();
#
#    my $statement = "select * from primer_pair where crRNA_id = ?;";
#
#    my $sth = $dbh->prepare($statement);
#
#    my @primer_pairs;
#    my $num_rows = $sth->execute( $crRNA->crRNA_id );
#    if( $sth->{'Executed'} ){
#   if( $num_rows > 0 ){
#       while( my @fields = $sth->fetchrow_array ){
#       my $primer_pair = Crispr::Primer_pair->new(
#           primer_pair_id => $fields[0],
#           primer_left => $fields[2],
#           primer_right => $fields[3],
#           type => $fields[4],
#           plate_id => $fields[5],
#           well_left => $fields[6],
#           well_right => $fields[7],
#       );
#       push @primer_pairs, $primer_pair;
#       }
#   }
#    }
#    $sth->finish();
#    return \@primer_pairs;
#}
#

=method delete_crRNA_from_db

  Usage       : $crRNA_adaptor->delete_crRNA_from_db( $crRNA );
  Purpose     : Delete a crRNA from the database
  Returns     : Crispr::DB::crRNA object
  Parameters  : Crispr::DB::crRNA object
  Throws      :
  Comments    : Not implemented yet.

=cut

sub delete_crRNA_from_db {
#   my ( $self, $crRNA ) = @_;
#
#   # first check crRNA exists in db
#
#   # delete primers and primer pairs
#
#   # delete transcripts
#
#   # if crRNA has talen pairs, delete tale and talen pairs
#
#
#
}

=method exists_in_db

  Usage       : $crRNA_adaptor->exists_in_db( $crRNA_name );
  Purpose     : Check whether a crRNA exists in the database
  Returns     : Crispr::DB::crRNA object
  Parameters  : Str (crRNA_name)
  Throws      :
  Comments    :

=cut

sub exists_in_db {
    my ( $self, $cr_name ) = @_;
    return $self->check_entry_exists_in_db( 'select count(*) from crRNA where crRNA_name = ?;', [ $cr_name ], );
}

#_check_well_and_contents
#
#  Usage       : $crRNAs = $crRNA_adaptor->_check_well_and_contents( $well, $type );
#  Purpose     : Internal method to check that well arguments to methods
#  Returns     : 1 on Success, throws otherwise
#  Parameters  : Well    (Labware::Well object)
#                Type    Str
#  Throws      : If the well is undef or is not a Labware::Well object
#                If the well is empty or if the contents are not a Crispr::crRNA object
#  Comments    : Type is used in any error messages and can be supplied to identify which method is checking the well
#

sub _check_well_and_contents {
    my ( $self, $well, $type, ) = @_;

    $type = !defined $type  ?   'stuff'  :   $type;
    if( !$well ){
        confess "A Labware::Well object must be supplied in order to add $type to the database!\n";
    }
    else{
        # check $well is a Labware::Well object
        if( !ref $well || !$well->isa('Labware::Well') ){
            confess "The supplied object must be a Labware::Well object, not ", ref $well, "!\n";
        }
    }

    my $crRNA = $well->contents;
    if( !$crRNA ){
        confess "The supplied well must contain a crRNA object to add to the database!\n";
    }
    else{
        # check $crRNA is a Crispr::crRNA object
        if( !ref $crRNA || !$crRNA->isa('Crispr::crRNA') ){
            confess "The contents of the supplied well must be a Crispr::crRNA object, not ", ref $crRNA, "!\n";
        }
    }
    return 1;
}

#_get_plate_id
  #
  #Usage       : $crRNAs = $crRNA_adaptor->_get_plate_id( $well, $type );
  #Purpose     : Internal method to check that well arguments to methods
  #Returns     : 1 on Success, throws otherwise
  #Parameters  : Well    (Labware::Well object)
  #              Type    Str
  #Throws      : If the well is undef or is not a Labware::Well object
  #              If the well is empty or if the contents are not a Crispr::crRNA object
  #Comments    : Type is used in any error messages and can be supplied to identify which method is checking the well
  #

sub _get_plate_id {
    my ( $self, $well, ) = @_;

    my $plate_adaptor = $self->get_adaptor( 'plate' );
    if( !$well->plate->plate_id ){
        # fetch plate id from db
        return $plate_adaptor->get_plate_id_from_name( $well->plate->plate_name );
    }
    else{
        return $well->plate->plate_id;
    }
}


__PACKAGE__->meta->make_immutable;
1;

__END__

=pod

=head1 SYNOPSIS

    use Crispr::DB::DBAdaptor;
    use Crispr::DB::crRNAAdaptor;

    # make a new db adaptor
    my $db_adaptor = Crispr::DB::DBAdaptor->new(
        host => 'HOST',
        port => 'PORT',
        dbname => 'DATABASE',
        user => 'USER',
        pass => 'PASS',
        connection => $dbc,
    );

    # get a crRNA adaptor using the get_adaptor method
    my $crRNA_adaptor = $db_adaptor->get_adaptor( 'crRNA' );


=head1 DESCRIPTION

    An object of this class represents a connector to a mysql database
    for retrieving crRNA objects from and storing them to the database.


=head1 SUBROUTINES/METHODS


=head1 DIAGNOSTICS


=head1 CONFIGURATION AND ENVIRONMENT



=head1 DEPENDENCIES


=head1 INCOMPATIBILITIES
