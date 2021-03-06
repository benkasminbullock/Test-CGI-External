#!/home/ben/software/install/bin/perl
use warnings;
use strict;
use Template;
use FindBin '$Bin';
use Perl::Build qw/get_commit get_info/;
use Perl::Build::Pod ':all';
use Deploy qw/do_system older/;
use Getopt::Long;
use File::Copy;
my $ok = GetOptions (
    'force' => \my $force,
    'verbose' => \my $verbose,
);
if (! $ok) {
    usage ();
    exit;
}

# Names of the input and output files containing the documentation.

my $pod = 'External.pod';
my $input = "$Bin/lib/Test/CGI/$pod.tmpl";
my $output = "$Bin/lib/Test/CGI/$pod";

#my $version = get_version ();
my $commit = get_commit ();
my $info = get_info ();

# Template toolkit variable holder

my %vars;

$vars{version} = $info->{version};
$vars{commit} = $commit;
$vars{info} = $info;

my $tt = Template->new (
    ABSOLUTE => 1,
    INCLUDE_PATH => [
	$Bin,
	pbtmpl (),
	"$Bin/examples",
    ],
    ENCODING => 'UTF8',
    FILTERS => {
        xtidy => [
            \& xtidy,
            0,
        ],
    },
    STRICT => 1,
);

copy "$Bin/t/bad-request.t", "$Bin/examples/bad-request.pl";

my @examples = <$Bin/examples/*.pl>;
for my $example (@examples) {
    my $output = $example;
    $output =~ s/\.pl$/-out.txt/;
    if (older ($output, $example) || $force) {
	do_system ("perl -I$Bin/blib/lib -I$Bin/blib/arch $example > $output 2>&1", $verbose);
    }
}

$tt->process ($input, \%vars, $output, binmode => 'utf8')
    or die '' . $tt->error ();

exit;

sub usage
{
print <<EOF;
--verbose
--force
EOF
}
