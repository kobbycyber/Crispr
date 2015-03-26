## no critic (RequireUseStrict, RequireUseWarnings, RequireTidyCode)
package Crispr::DB::SampleAdaptor;
## use critic

# ABSTRACT: SampleAdaptor object - object for storing Sample objects in and retrieving them from a SQL database

use namespace::autoclean;
use Moose;
use DateTime;
use Carp qw( cluck confess );
use English qw( -no_match_vars );
use List::MoreUtils qw( any );
use Crispr::DB::Sample;

extends 'Crispr::DB::BaseAdaptor';

my %sample_cache; # Cache for Sample objects. HashRef keyed on sample_id (db_id)

=method new

  Usage       : my $sample_adaptor = Crispr::DB::SampleAdaptor->new(
					db_connection => $db_connection,
                );
  Purpose     : Constructor for creating sample adaptor objects
  Returns     : Crispr::DB::SampleAdaptor object
  Parameters  :     db_connection => Crispr::DB::DBConnection object,
  Throws      : If parameters are not the correct type
  Comments    : The preferred method for constructing a SampleAdaptor is to use the
                get_adaptor method with a previously constructed DBConnection object

=cut

=method subplex_adaptor

  Usage       : $self->subplex_adaptor();
  Purpose     : Getter for a subplex_adaptor.
  Returns     : Crispr::DB::SubplexAdaptor
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

has 'subplex_adaptor' => (
    is => 'ro',
    isa => 'Crispr::DB::SubplexAdaptor',
    lazy => 1,
    builder => '_build_subplex_adaptor',
);

=method injection_pool_adaptor

  Usage       : $self->injection_pool_adaptor();
  Purpose     : Getter for a injection_pool_adaptor.
  Returns     : Crispr::DB::InjectionPoolAdaptor
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

has 'injection_pool_adaptor' => (
    is => 'ro',
    isa => 'Crispr::DB::InjectionPoolAdaptor',
    lazy => 1,
    builder => '_build_injection_pool_adaptor',
);


=method store

  Usage       : $sample = $sample_adaptor->store( $sample );
  Purpose     : Store a sample in the database
  Returns     : Crispr::DB::Sample object
  Parameters  : Crispr::DB::Sample object
  Throws      : If argument is not a Sample object
                If there is an error during the execution of the SQL statements
                    In this case the transaction will be rolled back
  Comments    : 

=cut

sub store {
    my ( $self, $sample, ) = @_;
	# make an arrayref with this one sample and call store_samples
	my @samples = ( $sample );
	my $samples = $self->store_samples( \@samples );
	
	return $samples->[0];
}

=method store_sample

  Usage       : $sample = $sample_adaptor->store_sample( $sample );
  Purpose     : Store a sample in the database
  Returns     : Crispr::DB::Sample object
  Parameters  : Crispr::DB::Sample object
  Throws      : If argument is not a Sample object
                If there is an error during the execution of the SQL statements
                    In this case the transaction will be rolled back
  Comments    : Synonym for store

=cut

sub store_sample {
    my ( $self, $sample, ) = @_;
	return $self->store( $sample );
}

=method store_samples

  Usage       : $samples = $sample_adaptor->store_samples( $samples );
  Purpose     : Store a set of samples in the database
  Returns     : ArrayRef of Crispr::DB::Sample objects
  Parameters  : ArrayRef of Crispr::DB::Sample objects
  Throws      : If argument is not an ArrayRef
                If objects in ArrayRef are not Crispr::DB::Sample objects
                If there is an error during the execution of the SQL statements
                    In this case the transaction will be rolled back
  Comments    : None
   
=cut

sub store_samples {
    my ( $self, $samples, ) = @_;
    my $dbh = $self->connection->dbh();
    
	confess "Supplied argument must be an ArrayRef of Sample objects.\n" if( ref $samples ne 'ARRAY');
	foreach my $sample ( @{$samples} ){
        if( !ref $sample || !$sample->isa('Crispr::DB::Sample') ){
            confess "Argument must be Crispr::DB::Sample objects.\n";
        }
    }
    
    my $add_sample_statement = "insert into sample values( ?, ?, ?, ?, ?, ?, ?, ?, ? );"; 
    
    $self->connection->txn(  fixup => sub {
        my $sth = $dbh->prepare($add_sample_statement);
        foreach my $sample ( @{$samples} ){
            # check subplex exists
            my $subplex_id;
            my ( $subplex_check_statement, $subplex_params );
            if( !defined $sample->subplex ){
                confess join("\n", "One of the Sample objects does not contain a Subplex object.",
                    "This is required to able to add the sample to the database.", ), "\n";
            }
            else{
                if( defined $sample->subplex->db_id ){
                    $subplex_check_statement = "select count(*) from subplex where subplex_id = ?;";
                    $subplex_params = [ $sample->subplex->db_id ];
                }
                else{
                    confess "Subplex object must have a database id!\n";
                }
            }
            # check subplex exists in db
            if( !$self->check_entry_exists_in_db( $subplex_check_statement, $subplex_params ) ){
                confess join(q{ }, "Sample,", $sample->subplex->db_id,
                             "does not exist in the database.", ), "\n";
            }
            
            # check injection pool for id and check it exists in the db
            my $injection_id;
            my ( $inj_pool_check_statement, $inj_pool_params );
            if( !defined $sample->injection_pool ){
                confess join("\n", "One of the Sample objects does not contain a InjectionPool object.",
                    "This is required to able to add the sample to the database.", ), "\n";
            }
            else{
                if( defined $sample->injection_pool->db_id ){
                    $inj_pool_check_statement = "select count(*) from injection where injection_id = ?;";
                    $inj_pool_params = [ $sample->injection_pool->db_id ];
                }
                elsif( defined $sample->injection_pool->pool_name ){
                    $inj_pool_check_statement = "select count(*) from injection i, injection_pool ip where injection_name = ? and ip.crRNA_id is NOT NULL;";
                    $inj_pool_params = [ $sample->injection_pool->pool_name ];
                }
            }
            # check injection_pool exists in db
            if( !$self->check_entry_exists_in_db( $inj_pool_check_statement, $inj_pool_params ) ){
                # try storing it
                $self->injection_pool_adaptor->store( $sample->injection_pool );
            }
            else{
                # need db_id
                if( !$injection_id ){
                    my $injection_pool = $self->injection_pool_adaptor->fetch_by_name( $sample->injection_pool->pool_name );
                    $injection_id = $injection_pool->db_id;
                }
            }
            
            # add sample
            $sth->execute(
                $sample->db_id, $sample->sample_name,
                $injection_id, $sample->subplex->db_id,
                $sample->well_id, $sample->barcode_id,
                $sample->generation, $sample->sample_type,
                $sample->species,
            );
            
            my $last_id;
            $last_id = $dbh->last_insert_id( 'information_schema', $self->dbname(), 'sample', 'sample_id' );
            $sample->db_id( $last_id );
        }
        $sth->finish();
    } );
    
    return $samples;
}

=method fetch_by_id

  Usage       : $samples = $sample_adaptor->fetch_by_id( $sample_id );
  Purpose     : Fetch a sample given its database id
  Returns     : Crispr::DB::Sample object
  Parameters  : crispr-db sample_id - Int
  Throws      : If no rows are returned from the database or if too many rows are returned
  Comments    : None

=cut

sub fetch_by_id {
    my ( $self, $id ) = @_;
    my $sample = $self->_fetch( 'sample_id = ?;', [ $id ] )->[0];
    if( !$sample ){
        confess "Couldn't retrieve sample, $id, from database.\n";
    }
    return $sample;
}

=method fetch_by_ids

  Usage       : $samples = $sample_adaptor->fetch_by_ids( \@sample_ids );
  Purpose     : Fetch a list of samples given a list of db ids
  Returns     : Arrayref of Crispr::DB::Sample objects
  Parameters  : Arrayref of crispr-db sample ids
  Throws      : If no rows are returned from the database for one of ids
                If too many rows are returned from the database for one of ids
  Comments    : None

=cut

sub fetch_by_ids {
    my ( $self, $ids ) = @_;
	my @samples;
    foreach my $id ( @{$ids} ){
        push @samples, $self->fetch_by_id( $id );
    }
	
    return \@samples;
}

=method fetch_by_name

  Usage       : $samples = $sample_adaptor->fetch_by_name( $sample_name );
  Purpose     : Fetch a sample given its database name
  Returns     : Crispr::DB::Sample object
  Parameters  : crispr-db sample_name - Str
  Throws      : If no rows are returned from the database or if too many rows are returned
  Comments    : None

=cut

sub fetch_by_name {
    my ( $self, $name ) = @_;
    my $sample = $self->_fetch( 'sample_name = ?;', [ $name ] )->[0];
    if( !$sample ){
        confess "Couldn't retrieve sample, $name, from database.\n";
    }
    return $sample;
}

=method fetch_all_by_plex_id

  Usage       : $samples = $sample_adaptor->fetch_all_by_plex_id( $plex_id );
  Purpose     : Fetch an sample given a plex database id
  Returns     : Crispr::DB::Sample object
  Parameters  : Int
  Throws      : If no rows are returned from the database or if too many rows are returned
  Comments    : None

=cut

sub fetch_all_by_subplex_id {
    my ( $self, $subplex_id ) = @_;
    my $samples = $self->_fetch( 'subplex_id = ?;', [ $subplex_id ] );
    if( !$samples ){
        confess join(q{ }, "Couldn't retrieve samples for subplex id, ",
                     $subplex_id, "from database.\n" );
    }
    return $samples;
}

=method fetch_all_by_subplex

  Usage       : $samples = $sample_adaptor->fetch_all_by_subplex( $subplex );
  Purpose     : Fetch an sample given a Subplex object
  Returns     : Crispr::DB::Sample object
  Parameters  : Crispr::DB::Subplex object
  Throws      : If no rows are returned from the database or if too many rows are returned
  Comments    : None

=cut

sub fetch_all_by_subplex {
    my ( $self, $subplex ) = @_;
    return $self->fetch_all_by_subplex_id( $subplex->db_id );
}

=method fetch_all_by_injection_id

  Usage       : $samples = $sample_adaptor->fetch_all_by_injection_id( $inj_id );
  Purpose     : Fetch an sample given an InjectionPool object
  Returns     : Crispr::DB::Sample object
  Parameters  : Crispr::DB::InjectionPool object
  Throws      : If no rows are returned from the database or if too many rows are returned
  Comments    : None

=cut

sub fetch_all_by_injection_id {
    my ( $self, $inj_id ) = @_;
    my $samples = $self->_fetch( 'injection_id = ?;', [ $inj_id ] );
    if( !$samples ){
        confess join(q{ }, "Couldn't retrieve samples for injection id,",
                     $inj_id, "from database.\n" );
    }
    return $samples;
}

=method fetch_all_by_injection_pool

  Usage       : $samples = $sample_adaptor->fetch_all_by_injection_pool( $inj_pool );
  Purpose     : Fetch an sample given an InjectionPool object
  Returns     : Crispr::DB::Sample object
  Parameters  : Crispr::DB::InjectionPool object
  Throws      : If no rows are returned from the database or if too many rows are returned
  Comments    : None

=cut

sub fetch_all_by_injection_pool {
    my ( $self, $inj_pool ) = @_;
    return $self->fetch_all_by_injection_id( $inj_pool->db_id );
}

#_fetch
#
#Usage       : $sample = $self->_fetch( \@fields );
#Purpose     : Fetch a Sample object from the database with arbitrary parameteres
#Returns     : ArrayRef of Crispr::DB::Sample objects
#Parameters  : where_clause => Str (SQL where clause)
#               where_parameters => ArrayRef of parameters to bind to sql statement
#Throws      : 
#Comments    : 

sub _fetch {
    my ( $self, $where_clause, $where_parameters ) = @_;
    my $dbh = $self->connection->dbh();
    
    my $sql = <<'END_SQL';
        SELECT
            sample_id, sample_name,
            injection_id, subplex_id,
            well_id, barcode_id,
            generation, type, species
        FROM sample
END_SQL

    if ($where_clause) {
        $sql .= 'WHERE ' . $where_clause;
    }
    
    my $sth = $self->_prepare_sql( $sql, $where_clause, $where_parameters, );
    $sth->execute();

    my ( $sample_id, $sample_name, $injection_id, $subplex_id,
            $well_id, $barcode_id, $generation, $type, $species, );
    
    $sth->bind_columns( \( $sample_id, $sample_name, $injection_id, $subplex_id,
            $well_id, $barcode_id, $generation, $type, $species, ) );

    my @samples = ();
    while ( $sth->fetch ) {
        
        my $sample;
        if( !exists $sample_cache{ $sample_id } ){
            # fetch subplex by subplex_id
            my $subplex = $self->subplex_adaptor->fetch_by_id( $subplex_id );
            # fetch injection pool by id
            my $injection_pool = $self->injection_pool_adaptor->fetch_by_id( $injection_id );
            
            $sample = Crispr::DB::Sample->new(
                db_id => $sample_id,
                injection_pool => $injection_pool,
                subplex => $subplex,
                barcode_id => $barcode_id,
                generation => $generation,
                sample_type => $type,
                well_id => $well_id,
                species => $species,
            );
            $sample_cache{ $sample_id } = $sample;
        }
        else{
            $sample = $sample_cache{ $sample_id };
        }
        
        push @samples, $sample;
    }

    return \@samples;    
}

sub delete_sample_from_db {
	#my ( $self, $sample ) = @_;
	
	# first check sample exists in db
	
	# delete primers and primer pairs
	
	# delete transcripts
	
	# if sample has talen pairs, delete tale and talen pairs

}

=method driver

  Usage       : $self->driver();
  Purpose     : Getter for the db driver.
  Returns     : Str
  Parameters  : None
  Throws      : If driver is not either mysql or sqlite
  Comments    : 

=cut

=method host

  Usage       : $self->host();
  Purpose     : Getter for the db host name.
  Returns     : Str
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

=method port

  Usage       : $self->port();
  Purpose     : Getter for the db port.
  Returns     : Str
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

=method dbname

  Usage       : $self->dbname();
  Purpose     : Getter for the database (schema) name.
  Returns     : Str
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

=method user

  Usage       : $self->user();
  Purpose     : Getter for the db user name.
  Returns     : Str
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

=method pass

  Usage       : $self->pass();
  Purpose     : Getter for the db password.
  Returns     : Str
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

=method dbfile

  Usage       : $self->dbfile();
  Purpose     : Getter for the name of the SQLite database file.
  Returns     : Str
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

=method connection

  Usage       : $self->connection();
  Purpose     : Getter for the db Connection object.
  Returns     : DBIx::Connector
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

=method db_params

  Usage       : $self->db_params();
  Purpose     : method to return the db parameters as a HashRef.
                used internally to share the db params around Adaptor objects
  Returns     : HashRef
  Parameters  : None
  Throws      : 
  Comments    : 

=cut

=method check_entry_exists_in_db

  Usage       : $self->check_entry_exists_in_db( $check_statement, $params );
  Purpose     : method used to check whether a particular entry exists in the database.
                Takes a MySQL statement of the form select count(*) from table where condition = ?;'
                and parameters
  Returns     : 1 if entry exists, undef if not
  Parameters  : check statement (Str)
                statement parameters (ArrayRef[Str])
  Throws      : 
  Comments    : 

=cut

=method fetch_rows_expecting_single_row

  Usage       : $self->fetch_rows_expecting_single_row( $sql_statement, $parameters );
  Purpose     : method to fetch a row from the database where the result should be unique.
  Returns     : ArrayRef
  Parameters  : MySQL statement (Str)
                Parameters (ArrayRef)
  Throws      : If no rows are returned from the database.
                If more than one row is returned.
  Comments    : 

=cut

=method fetch_rows_for_generic_select_statement

  Usage       : $self->fetch_rows_for_generic_select_statement( $sql_statement, $parameters );
  Purpose     : method to execute a generic select statement and return the rows from the db.
  Returns     : ArrayRef[Str]
  Parameters  : MySQL statement (Str)
                Parameters (ArrayRef)
  Throws      : If no rows are returned from the database.
  Comments    : 

=cut

=method _db_error_handling

  Usage       : $self->_db_error_handling( $error_message, $SQL_statement, $parameters );
  Purpose     : internal method to deal with error messages from the database.
  Returns     : Throws an exception that depends on the Adaptor type and
                the error message.
  Parameters  : Error Message (Str)
                MySQL statement (Str)
                Parameters (ArrayRef)
  Throws      : 
  Comments    : 

=cut

#_build_subplex_adaptor

  #Usage       : $subplex_adaptor = $self->_build_subplex_adaptor();
  #Purpose     : Internal method to create a new Crispr::DB::SubplexAdaptor
  #Returns     : Crispr::DB::SubplexAdaptor
  #Parameters  : None
  #Throws      : 
  #Comments    : 

sub _build_subplex_adaptor {
    my ( $self, ) = @_;
    return $self->db_connection->get_adaptor( 'subplex' );
}

#_build_injection_pool_adaptor

  #Usage       : $injection_pool_adaptor = $self->_build_injection_pool_adaptor();
  #Purpose     : Internal method to create a new Crispr::DB::InjectionPoolAdaptor
  #Returns     : Crispr::DB::InjectionPoolAdaptor
  #Parameters  : None
  #Throws      : 
  #Comments    : 

sub _build_injection_pool_adaptor {
    my ( $self, ) = @_;
    return $self->db_connection->get_adaptor( 'injection_pool' );
}



__PACKAGE__->meta->make_immutable;
1;

__END__

=pod
 
=head1 SYNOPSIS
 
    use Crispr::DB::DBAdaptor;
    my $db_adaptor = Crispr::DB::DBAdaptor->new(
        host => 'HOST',
        port => 'PORT',
        dbname => 'DATABASE',
        user => 'USER',
        pass => 'PASS',
        connection => $dbc,
    );
  
    my $sample_adaptor = $db_adaptor->get_adaptor( 'sample' );
    
    # store a sample object in the db
    $sample_adaptor->store( $sample );
    
    # retrieve a sample by id
    my $sample = $sample_adaptor->fetch_by_id( '214' );
  
    # retrieve a list of samples by date
    my $samples = $sample_adaptor->fetch_by_date( '2015-04-27' );
    

=head1 DESCRIPTION
 
 A SampleAdaptor is an object used for storing and retrieving Sample objects in an SQL database.
 The recommended way to use this module is through the DBAdaptor object as shown above.
 This allows a single open connection to the database which can be shared between multiple database adaptors.
 
=head1 DIAGNOSTICS
 
 
=head1 CONFIGURATION AND ENVIRONMENT
 
 
=head1 DEPENDENCIES
 
 
=head1 INCOMPATIBILITIES
 
