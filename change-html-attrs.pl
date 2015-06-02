#!/usr/bin/env perl

package BPJ::HTMLChangeAttrs;                   # {{{1}}}

use 5.008005;

use strict;
use warnings FATAL => 'all';
no warnings qw[ uninitialized numeric ];

use utf8;

use open ':utf8';
use open ':std';

# use autodie 2.12;

use subs qw[ dbg ];

use constant DEBUG => $ENV{"PERL_CHG_HTML_ATTRS"};
if ( DEBUG ) {
    eval <<'...';
    use Data::Dump qw[pp];
    sub dbg {
        my(undef, $file, $line) = caller;
        $file =~ s,.*[\\/],,;
        my $out = "$file:$line: " . pp(@_) . "\n";
        $out =~ s/^/# /gm;
        print STDERR $out;
    }
...
}

use CSS::Tiny;
use Carp;
use Clone::PP qw[ clone ];
use File::Basename qw[ basename ];
use File::Copy qw[ copy ];
use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case no_auto_abbrev ];
use HTML::TreeBuilder 5 -weak;
use IO::HTML qw[ html_file ];
use Pod::Usage;
use Scalar::Util qw[ blessed openhandle ];
use YAML::Tiny qw[ LoadFile ];
use charnames qw[ :full ];

# Constants for reference types.
# Use AREF etc. because some modules export ARRAY etc. constants!
use constant {
    AREF => ref([]),		# ARRAY
    CREF => ref(sub{}),		# CODE
    GREF => ref(*_),		# GLOB
    HREF => ref({}),		# HASH
    RREF => ref(\[]),		# REF
    SREF => ref(\1),		# SCALAR
    XREF => ref(qr/(?!)/),	# Regexp
};

my @default_attrs = ( [ from => 'class' ], [ to => '_tag' ] ); # {{{1}}}
my $name_re   = qr/([-\w]+)/;
my %selector_type = (
    _tag  => qr/(?<!\S)$name_re/,
    id    => qr/\#$name_re/,
    class => qr/\.$name_re/,
);

# ERROR {{{1}}}
my $program = basename($0);
sub _error {
    my $msg = shift;
    if ( @_ ) {
        $msg = sprintf $msg, @_;;
    }
    $msg =~ s/\s+/\N{SPACE}/g;
    $msg =~ s/\s*\z/\n/;
    confess "$program: $msg";
}

my @opt_specs = (                               # {{{1}}}
    'config|yaml|c|y=s',
    'css|C=s@',
    'body_only|body-only|b',
    'modify_in_place|modify-in-place|i:s',
    'stdout|s',
    'help|h',
    'man|m',
);

unless ( caller ) {    # Run as program          # {{{1}}}
    @ARGV
      or pod2usage(
        -msg     => 'Arguments required. Try -h for help!',
        -verbose => 0,
        -exitval => 2
      );
    my %opt = ();
    GetOptionsFromArray( \@ARGV, \%opt, @opt_specs )
      or pod2usage( -msg => 'Error getting options!', -verbose => 1, -exitval => 2 );
    $opt{man}  and pod2usage( -verbose => 2, -exitval => 0 );
    $opt{help} and pod2usage( -verbose => 1, -exitval => 0 );
    $opt{stdout} = 1 unless exists $opt{modify_in_place};
    __PACKAGE__->process( \%opt, @ARGV );
} ## end unless ( caller )


sub process {                                       # {{{1}}}
    my $self = shift;
    unless ( ref $self ) {
        my $class = $self;
        # warn $class;
        $self = $class->new( shift );
    }
    if ( @_ ) {
        my @args = @_;
        for my $arg ( @args ) {
            if ( blessed $arg and $arg->isa('HTML::Element') ) {
                $self->change($arg);
            }
            else {
                $arg = $self->process_file( $arg );
            }
        }
        return @args;
    }
    my $tree = $self->get_tree(\*STDIN);
    $self->change($tree);
    return $self->dump_html($tree);
}

sub new {                                # {{{1}}}
    my ( $class, $arg ) = @_;
    HREF eq ref $arg or _error "need some parameters";
    my $self = bless clone($arg) => $class;
    my $config = $self->{config} or _error "need some config";
    $self->load_config($config);
    if ( my $css = delete $self->{css} ) {
        AREF eq ref $css or $css = [$css];
        $self->find_styles( $css );
    }
    return $self;
} ## end sub get_self

sub load_config {    # {{{1}}}
    my ( $self, $config ) = @_;
    my $name = $config;
    if ( overload::Method( $name, q{""} ) ) {
        $name = "$name";
    }
    elsif ( ref $name ) {
        $name = 'config';
    }
    if ( -f $config ) {
        $config = LoadFile( $config );
    }
    elsif ( SREF eq ref $config ) {
        $config = Load( $$config );
    }
    else {
        $config = clone $config;
    }
    AREF eq ref $config and $config = +{ for_elements => $config };
    HREF eq ref $config
      or _error "expected $name to contain a hashmap or an arraylist";
  KEY:
    for my $key ( qw[ for_elements for_styles ] ) {
      PARAMS:
        for my $params ( $config->{$key} ) {
            $params ||= [];
            AREF eq ref $params or $params = [$params];
            if ( grep { HREF ne ref $_ } @$params ) {
                _error
                  "expected '$key' in $name to be arraylist of hashmaps or single hashmap";
            }
          PARAM:
            for my $param ( @$params ) {
                for my $key_attr ( @default_attrs ) {
                    my ( $key, $attr ) = @$key_attr;
                    for my $data ( $param->{$key} ) {
                        HREF eq ref $data or $data = +{ $attr => $data };
                    }
                } ## end for my $key_attr ( @default_attrs)
              FROM:
                for my $key ( keys %{ $param->{from} } ) {
                    for my $val ( $param->{from}{$key} ) {
                        $val =~ s!^/!! or next FROM;
                        my ( $mods ) = $val =~ m!/(\w*)$!;
                        $val = qr/(?$mods:$val)/;
                    }
                } ## end FROM: for my $key ( keys %{ $param...})
              TO:
                for my $to ( $param->{to} ) {
                    next unless $to->{CALL};
                    for my $calls ( $to->{CALL} ) {
                        AREF eq ref $calls or $calls = [$calls];
                        for my $call ( @$calls ) {
                            AREF eq ref $call or $call = [$call];
                        }
                    } ## end for my $calls ( $to->{CALL...})
                } ## end TO: for my $to ( $param->{to...})
            } ## end PARAM: for my $param ( @$params)
            $self->{$key} = $params;
        } ## end PARAMS: for my $params ( $config...)
    } ## end KEY: for my $key ( qw[ for_elements for_styles ])
} ## end sub load_config


sub find_styles {                               # {{{1}}}
    my ( $self, $css, $arg ) = @_;
    defined $css or _error "need some CSS";
    $arg ||= +{};
    HREF eq ref $arg or _error "extra arguments must be hashref";
    my( $for_styles, $for_elements ) = @{$arg}{qw[ for_styles for_elements ]};
    $for_styles ||= $self->{for_styles}   || return;
    $for_elements  ||= $self->{for_elements} ||= [];
    unless ( blessed $css and $css->isa('CSS::Tiny') ) {
        if ( blessed $css and $css->isa('HTML::Element') ) {
            my $style = $css->look_down( _tag => 'style' ) || return;
            $css = $style;
        }
        $css = $self->load_css_data( $css );
    }
    my @styles;
    while ( my ( $selectors, $style ) = each %$css ) {
        $selectors =~ s/\A\s+|\s+\z//g;
        next if $selectors =~ /(?<!,)\s+(?!,)/;
        for my $selector ( grep { /\S/ } split /\s*,\s*/, $selectors ) {
            my $attrs = clone $style;
            while ( my ( $key, $re ) = each %selector_type ) {
                my @values = $selector =~ /$re/g;
                next unless @values;
                $attrs->{$key} = "@values";
            }
            push @styles, $attrs;
        } ## end for my $selector ( grep...)
    } ## end while ( my ( $selectors, ...))
    return unless @styles;
    my @return;
    PARAMS:
    for my $params ( @$for_styles ) {
        my @found = @styles;
        FROM:
        for my $from ( $params->{from} ) {
            while ( my ( $attr, $val ) = each %$from ) {
                @found = grep { 
                    !defined($val) && !exists($_->{$attr})
                        or $_->{$attr} =~ $val 
                } @found;
                last FROM unless @found;
            }
        }
        next PARAMS unless @found;
        for my $to ( $params->{to} ) {
            for my $found ( @found ) {
                my $from = +{ map { ; $found->{$_} ? ( $_ => $found->{$_}  ) : () } qw[ _tag id class ] };
                push @return, +{ from => $from, to => $to };
            }
        }
    }
    unshift @$for_elements, @return;
    return $for_elements;
} 

sub process_file {                              # {{{1}}}
    my($self, $file) = @_;
    if ( openhandle $file ) {
        my $tree = $self->get_tree($file);
        $self->change($tree);
        return $self->dump_html( $tree );
    }
    elsif ( -f $file ) {
        my $in_place = exists $self->{modify_in_place};
        if ( $in_place ) {
            my $bak = $file . $self->{modify_in_place};
            copy( $file, $bak ) if $bak ne $file;
        }
        my $tree = $self->get_tree($file);
        $self->change($tree);
        my $html = $self->dump_html($tree);
        if ( $in_place ) {
            open my $fh, '>', $file;
            print {$fh} $html;
            close $fh;
        }
        return $html;
    }
}

sub change {    # {{{1}}}
    my ( $self, $tree ) = @_;
    $tree ||= $self->{tree};
    my @stylements;
    $self->find_styles( $tree, +{ for_elements => \@stylements } );
  PARAMS:
    for my $params ( $self->{for_elements} ) {
      PARAM:
        for my $param ( @stylements, @$params ) {
          FROM:
            for my $from ( $param->{from} ) {
              TO:
                for my $to ( $param->{to} ) {
                    my @elements = $tree->look_down( %$from );
                    @elements or next PARAM;
                  ELEM:
                    for my $element ( @elements ) {
                        {
                            delete local @{$to}{qw[ CALL ]};
                          ATTR:
                            while ( my ( $attr => $val ) = each %$to ) {
                                $element->attr( $attr => $val );
                            }
                        }
                      CALLS:
                        if ( my $calls = $to->{CALL} ) {
                          CALL:
                            for my $call ( @$calls ) {
                                my ( $method, @args ) = @$call;
                                next CALL unless $method;
                                $element->$method( @args );
                            }
                        } ## end CALLS: if ( my $calls = $to->...)
                    } ## end ELEM: for my $element ( @elements)
                } ## end TO: for my $to ( $param->{to...})
            } ## end FROM: for my $from ( $param->...)
        } ## end PARAM: for my $param ( @stylements...)
    } ## end PARAMS: for my $params ( $self->...)
    return $tree;
} ## end sub change

sub load_css_data {                              # {{{1}}}
    my ( $self, @args ) = @_;
    my $css;
    for my $arg ( @args ) {
        if ( -f $arg ) {
            $css .= do{ local $/; <>; };
        }
        if ( blessed $arg and $arg->isa('HTML::Element') ) {
            my $tag = $arg->tag;
            'style' eq $tag or _error "not a <style> element";
            my $element = $arg->clone;
            $element->tag('div'); # HTML::Element won't dump a style element as text!
            $css .= $element->as_text;
        }
        else {
            $css .= $arg;
        }
    }
    $css =~ s/\Q<!--\E.*?\Q-->\E//g;    # Remove HTML comments
    return CSS::Tiny->read_string( $css ) || _error CSS::Tiny->errstr;
} ## end sub load_css_data

sub get_fh {                                    # {{{1}}}
    my($self, $fn) = @_;
    return html_file($fn);
}

sub get_tree {                                  # {{{1}}}
    my( $self, $arg ) = @_;
    my $tree = HTML::TreeBuilder->new;
    $tree->ignore_ignorable_whitespace(0);
    if ( SREF eq ref $arg ) {
        $tree->parse_content( $$arg );
    }
    else {
        my $fh = openhandle( $arg ) ? $arg : $self->get_fh( $arg );
        $tree->parse_file( $fh );
    }
    return $tree;
}

sub dump_html {                                 # {{{1}}}
    my( $self, $tree, $opt ) = @_;
    $opt ||= +{};
    HREF eq ref $opt or _error "expected hashref with options";
    blessed $tree and $tree->isa('HTML::Element') or _error "need a tree to dump";
    my $stdout = defined($opt->{stdout}) ? $opt->{stdout} : $self->{stdout};
    my $body_only = defined($opt->{body_only}) ? $opt->{body_only} : $self->{body_only};
    if ( $body_only and my $body = $tree->look_down( _tag => 'body' ) ) {
        $tree = $body->clone;
        $tree->tag( 'div' );
    }
    elsif ( my $content_type = $tree->look_down( 
            _tag => 'meta', 'http-equiv' => "Content-Type",
            content => qr/\bcharset=(?!utf-8\b)/,
        ) ) {
        my $content = $content_type->attr( 'content' );
        $content =~ s/(?<=\bcharset=)[^;\s]+/utf-8/;
        $content_type->attr( 'content' => $content );
    }
    my $html = $tree->as_HTML( '<>&"', "\N{SPACE}\N{SPACE}", +{} );
    print STDOUT $html if $stdout;
    return $html;
}

1;

# END OF CODE                                   # {{{1}}}

__END__


# DOCUMENTATION                                 # {{{1}}}


=pod

=encoding UTF-8

=for Info: POD generated by pandoc-plain2pod.pl and pandoc.

=head1 NAME

change-html-attrs.pl - change tags and attributes of elements based on
their tags and elements

=head1 SYNOPSIS

    perl change-html-attrs.pl -c CONFIG-YAML [OPTIONS] [HTML-FILE...]

=head1 DESCRIPTION

C<< change-html-attrs.pl >> is a perl program which changes tags and
attributes of HTML elements based on their tags and elements.

The program reads a YAML configuration file, then an HTML file, passed
either as a filename or to I<< stdin >>, modifies HTML elements based on
criteria in the configuration file, converts the content back to HTML
and writes it to I<< stdout >>.

It is especially useful for correcting automatically generated (X)HTML
as output by e.g. by the XHTML export filter of LibreOffice Writer,
which uses C<< <span> >> elements with classes and a corresponding
embedded CSS stylesheet with styles like
C<< .T2 { font-style:italic; } >> rather than C<< <em> >> elements. I
have been told (I'm on Linux) that Apple's TextUtil, at least when
converting from RTF to HTML even replaces headers with styled C<< <p> >>
elements! Clearly these tools reflect the way the data are represented
in the original format, whether ODF XML or RTF too shallowly.

Unfortunately the correspondence between class names and styles
generated automatically by LibreOffice Writer or an RTF writer is not
constant, so one time you may get C<< .T2 { font-style:italic; } >> and
another time you get C<< .T5 { font-style:italic; } >> or some other
random, auto-generated class name for what should be an C<< <em> >>
element. To work around this you can use CSS property names and values
as search criteria, and if the HTML file contains any C<< <style> >>
elements these will be analysed to identify classes, ids and/or tags
corresponding to the specified CSS attributes and matching elements will
be modified accordingly.

=head1 OPTIONS


=over

=item C<< -c >>, C<< -y >>, C<< --config >>, C<< --yaml >> I<< FILE >>

The YAML config file to use. See L<< "The YAML config
file"|#the-yaml-config-file >> for its structure. This argument is
required.

=item C<< -C >>, C<< --css >> I<< FILE >> (Repeatable)

A CSS stylesheet file to use for mapping CSS styles to HTML attributes,
in addition to or instead of style sheet(s) embedded in the HTML
file(s). This option can be given more than once for multiple files.

=item C<< -b >>, C<< --body-only >>

Print out only the C<< <body> >> of the HTML documents, with the
C<< body >> element name replaced by C<< div >>.

When used in conjunction with C<< --modify-in-place >> this I<< will >>
lead to loss of any information in the C<< <head> >>!

=item C<< -i >>, C<< --modify-in-place >> [I<< .EXTENSION >>]

Write the modified HTML back to the original file after modification.
The modified content will be UTF-8 encoded regardless of the original
encoding and the C<< charset >> attribute of any
C<< <meta http-equiv="Content-Type"> >> element will have been updated
accordingly.

When I<< .EXTENSION >> is present the original file will be backed up to
a file with I<< .EXTENSION >> added to the filename.

If possible it is recommended to keep your files in a local git
repository and do the in-place modification in a fresh branch. If
anything goes wrong you can do C<< git reset --hard >> and return
everything to the state before modification. When all is done and well
you can merge the modification branch back into your main branch.

=item C<< -s >>, C<< --stdout >>

If both this option and C<< --modify-in-place >> are true modified HTML
will be written to I<< stdout >> as well as to files.

When C<< --modify-in-place >> is false C<< --stdout >> is implied and
all output will go to I<< stdout >>.

=item C<< -h >>, C<< --help >>

Show the help text.

=item C<< -m >>, C<< --man >>

Show the entire manual.


=back

=head1 USAGE

(For the format of the YAML configuration file see below!)

Apart from the C<< --config YAML_FILE >> option which I<< must >> be
present the program takes any number of HTML file names as arguments, or
reads a single file from I<< stdin >>.

The files are processed separately but if the C<< --modify-in-place >>
option is not used they are all written to I<< stdout >>.

When doing this the C<< --body-only >> option is useful as it causes the
C<< <body> >> of each input document, if any, to be output as a
C<< <div> >>.

Each input file is scanned for C<< <style> >> elements, which if found
are processed against the C<< for_styles: >> section of the config file,
using any resulting conversions in the processing of the current
document, in addition to (actually before) the conversions given in the
C<< for_elements: >> section of the config file and any conversions
derived from CSS files given with the C<< --css >> option.


=over

=item B<< WARNING: >>

If the HTML is not UTF-8 encoded you I<< must >> pass a filename, as
second argument and charset information must be present in the content
attribute of a C<< <meta http-equiv="Content-Type" >> tag in a possibly
incomplete HTML document, which will be looked up using the "two step"
algorithm specified by HTML5. It does not look for a BOM. Only the first
1024 bytes of the string are checked.


=back

The modified document will be converted back to HTML and written to
I<< stdout >> in UTF-8 encoding.

=head2 The YAML configuration file

The YAML configuration file should look something like this:

    ---
    for_styles:
      # Inline code
      - from:   # Search criteria
          class: '/^T\d+$'          # Leading / indicates regular expression
          font-family: '/Courier'
        to:     # replacement values
          _tag: code
          # Null replacement value: delete the attribute
          class: ~      
      - from:
          class: '/^T\d+$'
          font-style: '/italic'
        to:
          _tag: em
      - from:
          class: '/^T\d+$'
          font-style: '/bold'
        to:
          _tag: strong
      # Block code
      - from:
          margin-top: '/\S'
          font-family: '/Courier'
        to:
          _tag: pre
          class: ~

    for_elements:
      - from:
          _tag: p
        to:
          class: ~
      # Delete A elements without an href attribute
      - from:
          _tag: a
          # Null search value: the attribute must be nonexisting
          href: ~     
        to:
          CALL: delete    # Call a method on the HTML::Element object!
      # Delete classes from header elements
      - from:
          _tag: '/^h[1-6]$'
        to:
          class: ~

For the supported subset of YAML syntax see
L<< https://metacpan.org/pod/YAML::Tiny#YAML-TINY-SPECIFICATION|https://metacpan.org/pod/YAML::Tiny#YAML-TINY-SPECIFICATION >>

The structure of the configuration file is described below.

=head3 C<< for_styles: >> and C<< for_elements: >>

The top level is a mapping with at least one of the keys
C<< for_styles: >> and C<< for_elements >>, each with a list as value.
If the top level is a list it is assigned to C<< for_elements: >>

Each of the values of C<< for_styles: >> and C<< for_elements >> is a
list of mappings with two keys C<< from: >> (the search criteria) and
C<< to: >> (the replacement values), each with a mapping as value.

=head3 C<< from: >>

The C<< from: >> mapping of the C<< for_elements: >> list items have
HTML attribute names as keys and plain strings or strings containing
Perl regular expressions, or as explicitly null values specified with
C<< ~ >>, e.g. C<< href: ~ >>.

=head4 Regular expressions

Regular expressions are entered as normal strings and identified as
regexes by a leading forward slash and an optional trailing slash
followed by regular expression modifier letters:
C<< /REGEX/MODIFIERS >>, e.g. C<< /^P\d+$/i >> which matches a string
consisting of a C<< P >> or C<< p >> followed by one or more digits,
C<< /^P\d+$/ >> being the format of an automatical paragraph style class
in the output of LibreOffice Writer's XHTML exporter. Note that strings
containing regular expressions should normally be enclosed in single
quotes to prevent that punctuation characters inside them are
interpreted as YAML metacharacters.

If you are unfamiliar with regular expressions in general or Perl
regular expressions in particular you can find increasingly in-depth
information with the C<< perldoc >> command line program:

    $ perldoc perlrequick

    $ perldoc perlretut

    $ perldoc perlre

For the valid trailing modifiers see:

    $ perldoc -f qr

=head4 Element selection

The search criteria select all elements where all the criteria in the
C<< from: >> mapping match the corresponding HTML attributes:

    from:
        _tag:   span
        class:  '/\bfoo\b/'

selects all C<< <span> >> elements with a class C<< foo >>. Non-span
elements or elements without a C<< foo >> class are not selected.

The following rules apply for attribute value matching:


=over

=item Plain strings

Must match exactly, i.e. the attribute value must be that exact string.

=item Regular expressions

The attribute value must match the regular expression. If you don't want
to match a substring use the beginning-of-string and end-of-string
anchors C<< ^ >> and C<< $ >>.

=item Null search criterion values

The attribute must not be present in the element; thus C<< href: ~ >>
will match elements without any C<< href >> attribute.

Note that there is a subtle difference between an null value and an
empty string as search criterion values: the empty string will select
elements where the value of the attribute in question I<< is >> an empty
string, while an null value will select elements where the attribute in
question is missing.

=item The key C<< _tag: >>

The search criterion key C<< _tag: >>, with a leading underscore,
matches the I<< element name >> rather than an attribute. Thus
C<< _tag: span >> will select C<< <span> >> elements.

=item Classes

Remember that classes are stored in a single string separated by
whitespace. To match a single class enclose use a regular expressionand
enclose the class name with C<< \b >> anchors, or if the element should
have only a single class with C<< ^ >> and C<< $ >> anchors.


=back

=head4 In C<< for_styles: >>

The C<< from: >> mappings of the C<< for_styles: >> section are similar,
except that


=over


=item 1.

You can use CSS attribute names and values as search criteria. Thus for
example C<< font-family: '/Courier' >> will match elements to which a
style rule specifying Courier or Courier New as font-family apply.


=item 2.

The only HTML attributes you can match are C<< id >>, C<< class >> and
the element-name 'attribute' C<< _tag >>, namely as inferred from the
CSS selectors, which are matched against the following regular
expressions:

    _tag  : /(?<!\S)([-\w]+)/
    id    : /\#([-\w]+)/
    class : /\.([-\w]+)/


=back


=over

=item B<< NOTE: >>

Style matching works by matching the C<< from: >> criteria of the
C<< for_styles >> section against CSS style rules embedded in the HTML
document and constructing C<< for_elements >> criteria based on their
selectors.

Child selectors like C<< p.foo span.bar >> do not work. Such rules are
simply ignored. Comma-separated selectors like C<< p.foo, span.bar >>
I<< do >> work, but all other selectors containing whitespace are
ignored.


=back

=head3 C<< to: >>

C<< to: >> mappings simply specify string attribute values which should
replace the old attribute values -- or the element name; the C<< _tag >>
'attribute' is supported! A null value delete the attribute, so
C<< class: ~ >> will remove the C<< class >> attribute.

=head4 For Perl users

There is one possible key which does not just set an attribute string
value, distinguished by being uppercase:


=over

=item C<< CALL: >>

A list of lists, where the first item of the inner lists should be the
name of an L<< HTML::Element|HTML::Element >> method to call on the
object representing the element and the following items are arguments to
the method if any.

As a special shortcut you can give a single method name like
C<< CALL: delete >> instead of a list of lists.

Please note that this feature has not been extensively tested: the only
forms I have ever actually used are C<< CALL: delete >> and
C<< CALL: replace_with_content >>! These are arguably the most useful
ones.


=back

=head1 HISTORY

This is a more structured rewrite of a script which I have been using
for quite some time as a bridge when converting ODT and other formats
which can be opened by LibreOffice Writer to Markdown using
L<< pandoc|http://pandoc.org >> in order to get HTML which can be
meaningfully converted to Markdown by pandoc, in particular to get
actual C<< <em> >>, C<< <strong> >>, C<< <code> >> and C<< <pre> >>
elements rather than C<< <span> >> and C<< <p> >> elements, but also to
remove some cruft. The main addition is the support for inferring
elements which should be changed from CSS rules. Previously I had to
inspect every HTML file produced by LibreOffice visually and
write/modify a configuration file based on that. I had been thinking of
adding something like this for quite some time until a thread on the
pandoc-discuss Google group
L<< https://goo.gl/899dr8|https://goo.gl/899dr8 >> prompted me to
revisit the issue, and I realized it would be quite easy with the help
of L<< CSS::Tiny|CSS::Tiny >>, even using essentially the same
configuration format which I already used.

=head1 THE EXAMPLES


=over

=item C<< example.yaml >>

is geared towards cleaning up XHTML generated by LibreOffice Writer's
XHTML export filter for consumption by L<< pandoc|http://pandoc.org >>.

=item C<< example.odt >>

was generated by converting this documentation to XHTML using
[Pod::Simple::XHTML][] and [perldoc][], piping it to
L<< pandoc|http://pandoc.org >> for conversion to ODT.

=item C<< example.xhtml >>

was generated from C<< example.odt >> with LibreOffice and its XHTML
export filter.

=item C<< example-output.xhtml >>

was generated by running this program on C<< example.xhtml >> with
C<< example.yaml >> as configuration.

=item C<< example.sh >>

packages the process.


=back

=head1 AUTHOR

Benct Philip Jonsson
L<< bpjonsson@gmail.com|mailto:bpjonsson@gmail.com >>

=head1 COPYRIGHT

Copyright 2015- Benct Philip Jonsson

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

