package Plack::Handler::Mongrel2;
use strict;
use base qw(Plack::Handler);
our $VERSION = '0.01000';
use ZeroMQ qw( ZMQ_UPSTREAM ZMQ_PUB ZMQ_IDENTITY );
use JSON qw(decode_json);
use HTTP::Status qw(status_message);
use Parallel::Prefork;
use Plack::Util ();
use Plack::Util::Accessor
    qw(send_spec send_ident recv_spec recv_ident max_workers max_reqs_per_child);
use URI::Escape ();

# TODO
#   - check and fix what the correct way is to handle content-length
#     (mongrel2 chokes on simple requests if you don't responed with
#      content-length -- as of 8/20/2010)

sub _parse_netstring {
    my ($len, $rest) = split /:/, $_[0], 2;
    my $data = substr $rest, 0, $len, '';
    $rest =~ s/^,//;
    return ($data, $rest);
}

ZeroMQ::register_read_type( mongrel_req_to_psgi => sub {
    my ($rest, $headers, $body);

    my %env = (
        'psgi.version'      => [ 1, 1 ],
        'psgi.url_scheme'   => 'http', # XXX TODO
        'psgi.errors'       => *STDERR,
        'psgi.input'        => *STDOUT,
        'psgi.multithread'  => 0,
        'psgi.multiprocess' => 0,
        'psgi.run_once'     => 0,
        'psgi.streaming'    => 0,
        'psgi.nonblocking'  => 0,
    );

    ($env{MONGREL2_SENDER_ID}, $env{MONGREL2_CONN_ID}, $env{PATH_INFO}, $rest) =
        split / /, $_[0], 4;

    $env{PATH_INFO} = URI::Escape::uri_unescape($env{PATH_INFO});

    ($headers, $rest) = _parse_netstring($rest);

    my $hdrs = decode_json $headers;
    $env{QUERY_STRING}    = delete $hdrs->{QUERY} || '';
    $env{REQUEST_METHOD}  = delete $hdrs->{METHOD};
    $env{REQUEST_URI}     = delete $hdrs->{URI};
    $env{SCRIPT_NAME}     = delete $hdrs->{PATH} || '';
    $env{SERVER_PROTOCOL} = delete $hdrs->{VERSION};
    ($env{SERVER_NAME}, $env{SERVER_PORT}) = split /:/, delete $hdrs->{Host}, 2;

    foreach my $key (keys %$hdrs) {
        my $new_key = uc $key;
        $new_key =~ s/-/_/g;
        if ($new_key !~ /^(?:CONTENT_LENGTH|CONTENT_TYPE)$/) {
            $new_key = "HTTP_$new_key";
        }

        if (exists $env{$new_key}) {
            $env{$new_key} .= ", $hdrs->{$key}";
        } else {
            $env{$new_key} = $hdrs->{$key};
        }
    }

    ($body) = _parse_netstring($rest);
    open( my $fh, '<', \$body )
        or die "Could not open in memory buffer: $!";
    $env{'psgi.input'} = $fh;

    return \%env;
} );

sub new {
    my ($class, %opts) = @_;

    $opts{max_workers} ||= 10;
    $opts{max_reqs_per_child} ||= 100;

    bless { %opts }, $class;
}

sub run {
    my ($self, $app) = @_;

    foreach my $field qw(send_spec send_ident recv_spec recv_ident) {
        if (length $self->$field == 0) {
            die "Argument $field is required";
        }
    }

    my $max_workers = $self->max_workers;
    if ($max_workers > 0) {
        my $pm = Parallel::Prefork->new({
            max_workers => $max_workers,
            trap_signals => {
                TERM => 'TERM',
                HUP  => 'TERM',
            },
        });

        while ($pm->signal_received ne 'TERM') {
            $pm->start and next;
            $self->accept_loop($app);
            $pm->finish;
        }
        $pm->wait_all_children;
    } else {
        while (1) {
            $self->accept_loop($app);
        }
    }
}

sub accept_loop {
    my ($self, $app) = @_;

    my $ctxt     = ZeroMQ::Context->new();
    my $incoming = $ctxt->socket( ZMQ_UPSTREAM );
    my $outgoing = $ctxt->socket( ZMQ_PUB );

    $incoming->connect( $self->send_spec );
    $outgoing->connect( $self->recv_spec );
    $outgoing->setsockopt( ZMQ_IDENTITY, $self->send_ident );

    my $proc_req_count = 0;
    my $max_reqs_per_child = $self->max_reqs_per_child;
    while ( !defined $max_reqs_per_child || $proc_req_count < $max_reqs_per_child ) {
        my $env = $incoming->recv_as( 'mongrel_req_to_psgi' );
        eval {
            my $res = $app->( $env );
            $self->reply( $outgoing, $env, $res );
        };
        if ($@) {
            $self->reply( $outgoing, $env, [ 500, [ "Content-Type" => "text/plain" ], [ "Internal Server Error" ] ] );
        }

        $proc_req_count++;
    }

    $incoming->close();
    $outgoing->close();
}

sub reply {
    my ($self, $outgoing, $env, $res) = @_;

    my ($status, $hdrs, $body) = @$res;
    if (ref $body eq 'ARRAY') {
        $body = join '', @$body;
    } elsif ( defined $body) {
        local $/ = \65536 unless ref $/;
        my $x = '';
        while ( defined( my $line = $body->getline ) ) {
            $x .= $line;
        }
        $body->close;
        $body = $x;
    } else {
        die "unimplmented";
    }

    if ( ! Plack::Util::status_with_no_entity_body($status) ) {
        push @$hdrs, "Content-Length", length $body;
    }

    push @$hdrs, 'X-Plack-Test', $env->{HTTP_X_PLACK_TEST};
    my $mongrel_resp = sprintf( "%s %d:%s, %s %d %s\r\n%s\r\n\r\n%s",
        $env->{MONGREL2_SENDER_ID},
        length $env->{MONGREL2_CONN_ID},
        $env->{MONGREL2_CONN_ID},
        $env->{SERVER_PROTOCOL},
        $status,
        status_message($status),
        join("\r\n", map { sprintf( '%s: %s', $hdrs->[$_ * 2], $hdrs->[$_ * 2 + 1] ) } (0.. (@$hdrs/2 - 1) ) ),
        $body,
    );
    $outgoing->send( $mongrel_resp );
}

1;

__END__

=head1 NAME

Plack::Handler::Mogrel2 - Plack Handler For Mongrel2 

=head1 SYNOPSIS

    plackup -s Mongrel2 \
        --send_spec=tcp://127.0.0.1:9999 \
        --send_ident=D807E984-AC0B-11DF-979C-3C4975AD5E34 \
        --recv_spec=tcp://127.0.0.1:9998 \
        --recv_ident=E80576A8-AC0B-11DF-A841-3D4975AD5E34

=head1 DESCRIPTION

EXTERMELY ALPHA CODE!

=head1 METHODS

=head2 send_spec

The ZeroMQ spec for mongrel2-to-handler socket. Your handler will be
receiving requests from this socket.

=head2 send_ident

A unique identifier for the mongrel2-to-handler socket.

=head2 recv_spec

The ZeroMQ spec for handler-to-mongrel2 socket. Your handler will be
sending responses from this socket. 

=head2 recv_ident

A unique identifier for the handler-to-mongrel2 socket.

=head1 LICENSE

This library is available under Artistic License v2, and is:

    Copyright (C) 2010  Daisuke Maki C<< <daisuke@endeworks.jp> >>

=head1 AUTHOR

Daisuke Maki C<< <daisuke@endeworks.jp> >>

=cut