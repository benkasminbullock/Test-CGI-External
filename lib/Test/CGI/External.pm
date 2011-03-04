=head1 Test::CGI::External

Test::CGI::External - run tests on an external CGI program

=head1 SYNOPSIS

use Test::CGI::External;

my $tester = Test::CGI::External->new ();

$tester->set_cgi_executable ("x.cgi");

my %options;

# Automatically tests

$tester->run (\%options);

my $options{query_string} = 'text="alcohol"';

$tester->run (\%options);

# Test compression of output

$tester->do_compression_test (1);

=cut

package Test::CGI::External;
require Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw//;
use warnings;
use strict;
use autodie;
use Carp;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use IPC::Run3;

our $VERSION = 0.01;

=head1 METHODS

=cut

=head2 new

    my $tester = Test::CGI::External->new ();

Create a new testing object.

=cut

sub new
{
    my %tester;
    return bless \%tester;
}

=head2 set_cgi_executable

    $tester->set_cgi_executable ('my.cgi');

Set the CGI program to be tested to 'my.cgi'. This checks whether the
file exists and is executable, and prints a warning if either of these
checks fails.

=cut

sub set_cgi_executable
{
    my ($self, $cgi_executable) = @_;
    if ($self->{verbose}) {
        print "I am setting the CGI executable to be tested to '$cgi_executable'.\n";
    }
    if (! -f $cgi_executable) {
        carp "I cannot find a file corresponding to CGI executable '$cgi_executable'";
    }
    elsif (! -x $cgi_executable) {
        carp "The CGI executable '$cgi_executable' exists but is not executable";
    }
    elsif ($self->{verbose}) {
        print "This executable exists and is executable.\n";
    }
    $self->{cgi_executable} = $cgi_executable;
}

=head2 do_compression_test

    $tester->do_compression_test (1);

Turn on or off testing of compression of the output of the CGI program
which is being tested. Give any true value as the first argument to
turn on compression testing. Give any false value to turn off
compression testing.

=cut

sub do_compression_test
{
    my ($self, $switch) = @_;
    $switch = !! $switch;
    if ($self->{verbose}) {
        print "You have asked me to turn ";
        if ($switch) {
            print "on";
        }
        else {
            print "off";
        }
        print " testing of compression.\n";
    }
    $self->{comp_test} = $switch;
}

=head2 expect_charset

    $tester->expect_charset ('UTF-8');

Tell the tester to test whether the header and output have the correct
character set.

=cut

sub expect_charset
{
    my ($self, $charset) = @_;
    if ($self->{verbose}) {
        print "You have told me to expect a 'charset' value of '$charset'.\n";
    }
    $self->{expected_charset} = $charset;
}

=head2 set_verbosity

    $tester->set_verbosity (1);

This turns on or off messages from the module informing you of what it
is doing.

=cut

sub set_verbosity
{
    my ($self, $verbosity) = @_;
    $self->{verbose} = !! $verbosity;
    if ($self->{verbose}) {
        print "You have asked ", __PACKAGE__, " to print messages as it works.\n";
    }
}

sub check_request_method
{
    my ($request_method) = @_;
    my $default_request_method = 'GET';
    if ($request_method) {
        my @request_method_list = qw/POST GET HEAD/;
        my %valid_request_method = map {$_ => 1} @request_method_list;
        if ($request_method && ! $valid_request_method{$request_method}) {
            carp "You have set the request method to a value '$request_method' which is not one of the ones I know about, which are ", join (', ', @request_method_list), " so I am setting it to the default, '$default_request_method'";
            $request_method = $default_request_method;
        }
    } else {
        carp "You have not set the request method, so I am setting it to the default, '$default_request_method'";
        $request_method = $default_request_method;
    }
    return $request_method;
}

# Register a successful test

sub pass_test
{
    my ($self, $test) = @_;
    if ($self->{verbose}) {
        print "Success: $test.\n";
    }
    $self->{successes} += 1;
    $self->{tests} += 1;
}

# Fail a test and keep going.

sub fail_test
{
    my ($self, $test) = @_;
    print STDERR "Failed a test: $test.\n";
    $self->{failures} += 1;
    $self->{tests} += 1;
}

# Fail a test which means that we cannot keep going.

sub abort_test
{
    my ($self, $test) = @_;
    die "$test.\n";
}

sub setenv_private
{
    my ($object, $name, $value) = @_;
    if (! $object->{set_env}) {
        $object->{set_env} = [$name];
    }
    else {
        push @{$object->{set_env}}, $name;
    }
    if ($ENV{$name}) {
        carp "A variable '$name' is already set in the environment.\n";
    }
    $ENV{$name} = $value;
}

# Internal routine to run a CGI program.

sub run_private
{
    my ($object) = @_;

    # Pull everything out of the object and into normal variables.

    my $verbose = $object->{verbose};
    my $options = $object->{run_options};
    my $cgi_executable = $object->{cgi_executable};
    my $comp_test = $object->{comp_test};

    # Hassle up the CGI inputs, including environment variables, from
    # the options the user has given.

    my $query_string = $options->{QUERY_STRING};
    if (defined $query_string) {
        if ($verbose) {
            print "I am setting the query string to '$query_string'.\n";
        }
        setenv_private ($object, 'QUERY_STRING', $query_string);
    }
    elsif ($verbose) {
        print "There is no query string.\n";
    }
    my $request_method = check_request_method ($options->{REQUEST_METHOD});
    if ($verbose) {
        print "The request method is '$request_method'.\n";
    }
    setenv_private ($object, 'REQUEST_METHOD', $request_method);
    my $input;
    if ($options->{input}) {
        $input = $options->{input};
        my $content_length = length ($input);
        setenv_private ($object, 'CONTENT_LENGTH', $content_length);
        if ($verbose) {
            print "I am setting the CGI program's standard input to a string of length $content_length taken from the input options.\n";
        }
    }

    if ($comp_test) {
        if ($verbose) {
            print "I am requesting gzip encoding from the CGI executable.\n";
        }
        setenv_private ($object, 'HTTP_ACCEPT_ENCODING', 'gzip, fake');
    }

    # Actually run the executable under the current circumstances.

    my $standard_output;
    my $error_output;
    if ($verbose) {
        print "I am running the program.\n";
    }
    run3 ($cgi_executable, \$input, \$standard_output, \$error_output);
    if ($verbose) {
        printf "The program has now finished running. There were %d bytes of output.\n", length ($standard_output);
    }
    $options->{exit_code} = $?;
    if ($options->{exit_code} != 0) {
        $object->abort_test ("The CGI executable exited with non-zero status");
    }
    else {
        $object->pass_test ("The CGI executable exited with a zero status");
    }
    $options->{output} = $standard_output;
    if (! $options->{output}) {
        $object->abort_test ("The CGI executable did not produce any output");
    }
    else {
        $object->pass_test ("The CGI executable produced some output");
    }
    $options->{error_output} = $error_output;
    return;
}


# my %token_valid_chars;
# @token_valid_chars{0..127} = (1) x 128;
# my @ctls = (0..31,127);
# @token_valid_chars{@ctls} = (0) x @ctls;
# my @tspecials = 
#     ('(', ')', '<', '>', '@', ',', ';', ':', '\\', '"',
#      '/', '[', ']', '?', '=', '{', '}', \x32, \x09 );
# @token_valid_chars{@tspecials} = (0) x @tspecials;

sub HTTP_CTL {
    return <<'END';
0000 001F
007F
END
}

sub HTTP_TSPECIALS {
    return <<'END';
0009
0020
0022
0028
0029
002C
002F
003A 003F
005B 005D
007B
007D
END
}

sub HTTP_TOKEN {
    return <<'END';
0000 007f
-Test::CGI::External::HTTP_CTL
-Test::CGI::External::HTTP_TSPECIALS
END
}

sub HTTP_TEXT {
    return <<'END';
0000 00ff
-Test::CGI::External::HTTP_CTL
END
}

# This does not include [CRLF].

sub HTTP_LWS {
    return <<'END';
0009
0020
END
}

my $qd_text = qr/[^"\p{HTTP_CTL}]/;
my $quoted_string = qr/"$qd_text+"/;
my $field_content = qr/\p{HTTP_TEXT}*|
                       (?:
                           \p{HTTP_TOKEN}|
                           \p{HTTP_TSPECIALS}|
                           $quoted_string
                       )*
                      /x;

my $http_token = qr/\p{HTTP_TOKEN}+/;

# Check for a valid content type line.

sub check_content_line_private
{
    my ($object, $header, $verbose) = @_;

    my $expected_charset = $object->{expected_charset};
    my $content_type_line;

    if ($verbose) {
        print "I am checking to see if the output contains a valid content type line.\n";
    }
    my $content_type_ok;
    if ($header =~ m!(Content-Type:\s*.*)!i) {
        $object->pass_test ("There is a Content-Type header");
        $content_type_line = $1;
        if ($content_type_line =~ m!^Content-Type:\p{HTTP_LWS}+
                                        \p{HTTP_TOKEN}+
                                        /
                                        \p{HTTP_TOKEN}+
                                   !xi) {
            $object->pass_test ("The Content-Type header is well-formed");
            if ($expected_charset) {
                if ($content_type_line =~ /charset
                                           =
                                           (
                                               $http_token|
                                               $quoted_string
                                           )/xi) {
                    my $charset = $1;
                    $charset =~ s/^"(.*)"$/$1/;
                    if (lc $charset ne lc $expected_charset) {
                        $object->fail_test ("You told me to expect a charset value of '$expected_charset', but the content-type line of the CGI executable, '$content_type_line', contains a charset parameter with the value '$charset'");
                    }
                    else {
                        $content_type_ok = 1;
                        $object->pass_test ("The charset '$charset' corresponds to the one you said to expect, '$expected_charset'");
                    }
                }
                else {
                    $object->fail_test ("You told me to expect a charset (character set) value of '$expected_charset', but the content-type line of the CGI executable, '$content_type_line', does not contain a valid 'charset' parameter");
                }
            }
            else {
                $content_type_ok = 1;
                if ($verbose) {
                    print "I am not testing for the 'charset' parameter.\n";
                }
            }
        }
        else {
            $object->fail_test ("The Content-Type line '$content_type_line' does not match the specification required.");
        }
    }
    else {
        $object->fail_test ("There is no 'Content-Type' line in the output.");
    }
    if ($content_type_ok && $verbose) {
        print "The content-type line appears to be OK.\n";
    }
}

sub check_http_header_syntax_private
{
    my ($object, $header, $verbose) = @_;
    if ($verbose) {
        print "I am checking the HTTP header produced.\n";
    }
    my @lines = split /\r?\n/, $header;
    my $line_number = 0;
    my $bad_headers = 0;
    for my $line (@lines) {
        if ($line =~ /^$/) {
            if ($line_number == 0) {
                $object->fail_test ("The output of the CGI executable has a blank line as its first line");
            }
            else {
                $object->pass_test ("There are $line_number valid header lines");
            }
            # We have finished looking at the headers.
            last;
        }
        $line_number += 1;
        if ($line !~ /\p{HTTP_TOKEN}:\p{HTTP_LWS}/) {
            $object->fail_test ("The header on line $line_number, '$line', appears not to be a correctly-formed HTTP header");
            $bad_headers++;
        }
        else {
            $object->pass_test ("The header on line $line_number, '$line', appears to be a correctly-formed HTTP header");
        }
    }
    if ($verbose) {
        print "I have finished checking the HTTP header.\n";
    }
}

# Check whether the headers of the CGI output are well-formed.

sub check_headers_private
{
    my ($object) = @_;

    # Extract variables from the object

    my $verbose = $object->{verbose};
    my $output = $object->{run_options}->{output};
    if (! $output) {
        die "An error has occured in ", __PACKAGE__, ": the output should have been checked for emptiness but somehow it hasn't been, and so I cannot continue working. Sorry!";
    }
    my ($header, $body) = split /\r?\n\r?\n/, $output, 2;
    check_http_header_syntax_private ($object, $header, $verbose);
    check_content_line_private ($object, $header, $verbose);
    $object->{run_options}->{header} = $header;
    $object->{run_options}->{body} = $body;
}

sub check_compression_private
{
    my ($object) = @_;
    my $body = $object->{run_options}->{body};
    my $header = $object->{run_options}->{header};
    my $verbose = $object->{verbose};
    if ($verbose) {
        print "I am testing whether compression has been applied to the output.\n";
    }
    if ($header !~ /Content-Encoding:.*\bgzip\b/i) {
        $object->fail_test ("Output '$header' does not have a header indicating compression");
    }
    else {
        $object->pass_test ("The header claims that the output is compressed");
        my $discard;
        #printf "The length of the body is %d\n", length ($body);
        my $status = gunzip \$body => \$discard;
        if (! $status) {
            $object->fail_test ("Output claims to be in gzip format but gunzip on the output failed with the error '$GunzipError'");
            my $failedfile = "$0.gunzip-failure.$$";
            open my $temp, ">:bytes", $failedfile or die $!;
            print $temp $body;
            close $temp;
            print "Saved failed output to $failedfile.\n";
        }
        else {
            $object->pass_test ("The body of the CGI output was able to be decompressed using 'gunzip'");
        }
    }
    if ($verbose) {
        print "I have finished testing the compression.\n";
    }
}

=head2 run

    my %options;
    $options{query} = "q=rupert+the+bear";
    $tester->run (\%options);

Run the cgi executable specified using L<set_cgi_executable> with the
inputs specified in C<%options>.

=cut

sub run
{
    my ($self, $options) = @_;
    for my $t (qw/tests failures successes/) {
        $self->{$t} = 0;
    }
    if (! $self->{cgi_executable}) {
        croak "You have requested me to run a CGI executable with 'run' without telling me what it is you want me to run. Please tell me the name of the CGI executable using the method 'set_cgi_executable'.";
    }
    if (! $options) {
        $self->{run_options} = {};
        carp "You have requested me to run a CGI executable with 'run' without specifying a hash reference to store the input, output, and error output. I can only run basic tests of correctness";
    }
    else {
        $self->{run_options} = $options;
    }
    if ($self->{verbose}) {
        print "I am commencing the testing of CGI executable '$self->{cgi_executable}'.\n";
    }
#    eval {
    run_private ($self);
    check_headers_private ($self);
    if ($self->{comp_test}) {
        check_compression_private ($self);
    }
#    if ($self->{verbose}) {
        print "There were $self->{tests} tests. Of these, $self->{successes} succeeded and $self->{failures} failed.\n";
        print "My name is Michael Caine. Not a lot of people know that.\n";
#    }
    for my $e (@{$self->{set_env}}) {
#        print "Deleting environment variable $e\n";
        $ENV{$e} = undef;
    }
    $self->{set_env} = undef;
#    };
#    if ($@) {
#        print STDERR "The following fatal errors occurred: $@\n";
#    }
}

1;
