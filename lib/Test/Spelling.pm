package Test::Spelling;
use 5.006;
use strict;
use warnings;

use base 'Exporter';
use Pod::Spell;
use Test::Builder;
use File::Spec;
use IPC::Open3;

our $VERSION = '0.12';

our @EXPORT = qw(
    pod_file_spelling_ok
    all_pod_files_spelling_ok
    add_stopwords
    set_spell_cmd
    all_pod_files
    set_pod_file_filter
    has_working_spellchecker
);

my $Test = Test::Builder->new;

my $SPELLCHECKER;
my $file_filter = sub { 1 };

sub spellchecker_candidates {
    # if they've specified a spellchecker, use only that one
    return $SPELLCHECKER if $SPELLCHECKER;

    return (
        'spell', # for back-compat, this is the top candidate ...
        'aspell list -l en', # ... but this should become first soon
        'ispell -l',
        'hunspell -l',
    );
}

sub has_working_spellchecker {
    my $dryrun_results = _get_spellcheck_results("dry run", 1);

    if (ref $dryrun_results) {
        return;
    }

    return $SPELLCHECKER;
}

sub _get_spellcheck_results {
    my $document = shift;
    my $dryrun = shift;

    my @errors;

    for my $spellchecker (spellchecker_candidates()) {
        my @words;
        my $ok = eval {
            my $pid = open3((my ($child_in, $spellcheck_results, $child_err)), $spellchecker);

            print $child_in $document;

            # signal to spellchecker that we're done giving it words
            close $child_in or die $!;

            @words = <$spellcheck_results>;

            # wait for spellchecker to clean up
            waitpid $pid, 0;

            1;
        };

        if ($ok) {
            # remember the one we used, so that it's consistent for all the files
            # this run, and we don't keep retrying the same spellcheckers that will
            # never work. also we need to expose the spellchecker we're using in
            # has_working_spellchecker
            set_spell_cmd($spellchecker)
                if !$SPELLCHECKER;
            return @words;
        }

        push @errors, "Unable to run '$spellchecker': $@";
    }

    # no working spellcheckers during a dry run
    return \"no spellchecker" if $dryrun;

    # no working spellcheckers; report all the errors
    require Carp;
    Carp::croak
        "Unable to find a working spellchecker:\n"
        . join("\n", map { "    $_\n" } @errors)
}

sub invalid_words_in {
    my $file = shift;

    my $document = '';
    open my $handle, '>', \$document;

    # save digested POD to the string $document
    my $checker = Pod::Spell->new;
    $checker->parse_from_file($file, $handle);

    my @words = _get_spellcheck_results($document);

    chomp for @words;
    return @words;
}

sub pod_file_spelling_ok {
    my $file = shift;
    my $name = shift || "POD spelling for $file";

    if (!-r $file) {
        $Test->ok(0, $name);
        $Test->diag("$file does not exist or is unreadable");
        return;
    }

    my @words = invalid_words_in($file);

    # remove stopwords, select unique errors
    @words = grep { !$Pod::Wordlist::Wordlist{$_} } @words;
    my %seen;
    @seen{@words} = ();
    @words = sort keys %seen;

    # emit output
    my $ok = @words == 0;
    $Test->ok($ok, "$name");
    if (!$ok) {
        $Test->diag("Errors:\n" . join '', map { "    $_\n" } @words);
    }

    return $ok;
}

sub all_pod_files_spelling_ok {
    my @files = all_pod_files(@_);

    if (!has_working_spellchecker()) {
        return $Test->plan(skip_all => "no working spellchecker found");
    }

    $Test->plan(tests => scalar @files);

    my $ok = 1;
    for my $file (@files) {
        pod_file_spelling_ok($file) or undef $ok;
    }
    return $ok;
}

sub all_pod_files {
    my @queue = @_ ? @_ : _starting_points();
    my @pod;

    while (@queue) {
        my $file = shift @queue;

        # recurse into subdirectories
        if (-d $file) {
            opendir(my $dirhandle, $file) or next;
            my @newfiles = readdir($dirhandle);
            closedir $dirhandle;

            @newfiles = File::Spec->no_upwards(@newfiles);
            @newfiles = grep { $_ ne "CVS" && $_ ne ".svn" } @newfiles;

            push @queue, map "$file/$_", @newfiles;
        }

        # add the file if it meets our criteria
        if (-f $file) {
            next unless _is_perl($file);
            next unless $file_filter->($file);
            push @pod, $file;
        }
    }

    return @pod;
}

sub _starting_points {
    return 'blib' if -d 'blib';
    return 'lib';
}

sub _is_perl {
    my $file = shift;

    return 1 if $file =~ /\.PL$/;
    return 1 if $file =~ /\.p(l|lx|m|od)$/;
    return 1 if $file =~ /\.t$/;

    open my $handle, '<', $file or return;
    my $first = <$handle>;

    return 1 if defined $first && ($first =~ /^#!.*perl/);

    return 0;
}

sub add_stopwords {
    for my $word (@_) {
        $word =~ s/^#?\s*//;
        $word =~ s/\s+$//;
        next if $word =~ /\s/ or $word =~ /:/;
        $Pod::Wordlist::Wordlist{$word} = 1;
    }
}

sub set_spell_cmd {
    $SPELLCHECKER = shift;
}

sub set_pod_file_filter {
    $file_filter = shift;
}

1;

__END__

=head1 NAME

Test::Spelling - check for spelling errors in POD files

=head1 SYNOPSIS

C<Test::Spelling> lets you check the spelling of a POD file, and report
its results in standard C<Test::Simple> fashion. This module requires the
F<spell> program.

    use Test::More;
    use Test::Spelling;
    plan tests => $num_tests;
    pod_file_spelling_ok($file, "POD file spelling OK");

Module authors can include the following in a F<t/pod_spell.t> file and
have C<Test::Spelling> automatically find and check all POD files in a
module distribution:

    use Test::More;
    use Test::Spelling;
    all_pod_files_spelling_ok();

Note, however that it is not really recommended to include this test with a
CPAN distribution, or a package that will run in an uncontrolled environment,
because there's no way of predicting if F<spell> will be available or the
word list used will give the same results (what if it's in a different language,
for example?). You can have the test, but don't add it to F<MANIFEST> (or add
it to F<MANIFEST.SKIP> to make sure you don't add it by accident). Anyway,
your users don't really need to run this test, as it is unlikely that the
documentation will acquire typos while in transit. :-)

You can add your own stopwords (words that should be ignored by the spell
check):

    add_stopwords(qw(asdf thiswordiscorrect));

These stopwords are global for the test. See L<Pod::Spell> for a variety of
ways to add per-file stopwords to each .pm file.

=head1 DESCRIPTION

Check POD files for spelling mistakes, using L<Pod::Spell> and F<spell> to do
the heavy lifting.

=head1 FUNCTIONS

=head2 pod_file_spelling_ok( FILENAME[, TESTNAME ] )

C<pod_file_spelling_ok()> will okay the test if the POD has no spelling errors.

When it fails, C<pod_file_spelling_ok()> will show any spelling errors as
diagnostics.

The optional second argument TESTNAME is the name of the test.  If it
is omitted, C<pod_file_spelling_ok()> chooses a default test name "POD spelling
for FILENAME".

=head2 all_pod_files_spelling_ok( [@files/@directories] )

Checks all the files in C<@files> for POD spelling.  It runs L<all_pod_files()>
on each file/directory, and calls the C<plan()> function for you (one test for
each function), so you can't have already called C<plan>.

If C<@files> is empty or not passed, the function finds all POD files in
the F<blib> directory if it exists, or the F<lib> directory if not.
A POD file is one that ends with F<.pod>, F<.pl>, F<.plx>, or F<.pm>; or any
file where the first line looks like a shebang line.

If you're testing a module, just make a F<t/spell.t>:

    use Test::More;
    use Test::Spelling;
    all_pod_files_spelling_ok();

Returns true if all pod files are ok, or false if any fail.

=head2 all_pod_files( [@dirs] )

Returns a list of all the Perl files in I<$dir> and in directories below.
If no directories are passed, it defaults to F<blib> if F<blib> exists,
or else F<lib> if not.  Skips any files in CVS or .svn directories.

A Perl file is:

=over 4

=item * Any file that ends in F<.PL>, F<.pl>, F<.plx>, F<.pm>, F<.pod> or F<.t>.

=item * Any file that has a first line with a shebang and "perl" on it.

=back

Furthermore, files for which the filter set by L</set_pod_file_filter> return
false are skipped. By default this filter passes everything through.

The order of the files returned is machine-dependent.  If you want them
sorted, you'll have to sort them yourself.

=head2 add_stopwords(@words)

Add words that should be skipped by the spell check. A suggested use is to list
these words, one per line, in the __DATA__ section of your test file, and just
call

    add_stopwords(<DATA>);

As a convenience, C<add_stopwords> will automatically ignore a comment mark and
one or more spaces from the beginning of the line, and it will ignore lines
that say '# Error:' or '# Looks like' or /Failed test/. The reason? Let's say
you run a test and get this result:

    1..1
    not ok 1 - POD spelling for lib/Test/Spelling.pm
    #     Failed test (lib/Test/Spelling.pm at line 70)
    # Errors:
    #     stopwords
    # Looks like you failed 1 tests of 1.

Let's say you decide that all the words that were marked as errors are really
correct. The diagnostic lines are printed to STDERR; that means that, if you
have a decent shell, you can type something like

    perl t/spell.t 2>> t/spell.t

which will append the diagnostic lines to the end of your test file. Assuming
you already have a __DATA__ line in your test file, that should be enough to
ensure that the test passes the next time.

Also note that L<Pod::Spell> skips words believed to be code, such as words
in verbatim blocks and code labeled with CE<lt>>.

=head2 set_spell_cmd($command)

If the F<spell> program has a different name or is not in your path, you can
specify an alternative with C<set_spell_cmd>. Any command that takes text
from standard input and prints a list of misspelled words, one per line, to
standard output will do. For example, you can use C<aspell list>.

=head2 set_pod_file_filter($code)

If your project has POD documents written in languages other than English, then
obviously you don't want to be running a spellchecker on every Perl file.
C<set_pod_file_filter> lets you filter out files returned from
L</all_pod_files> (and hence, the documents tested by
L</all_pod_files_spelling_ok>).

    set_pod_file_filter(sub {
        my $filename = shift;
        return 0 if $filename =~ /_ja.pod$/; # skip Japanese translations
        return 1;
    });

=head1 SEE ALSO

L<Pod::Spell>

=head1 ORIGINAL AUTHOR

Ivan Tubert-Brohman C<< <itub@cpan.org> >>

Heavily based on L<Test::Pod> by Andy Lester and brian d foy.

=head1 MAINTAINER

Shawn M Moore C<< <sartak@bestpractical.com> >>

=head1 COPYRIGHT

Copyright 2005, Ivan Tubert-Brohman, All Rights Reserved.

You may use, modify, and distribute this package under the
same terms as Perl itself.

=cut

