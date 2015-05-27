#!/usr/bin/env perl

package BPJ::HTMLChangeAttrs;

use 5.008005;
use strict;
use warnings FATAL => 'all';
no warnings qw[ uninitialized numeric ];

use utf8;

use open ':utf8';
use open ':std';

# use autodie 2.12;

use Data::Dump qw[dd];

use Carp;
use File::Basename qw[basename];
use YAML::Tiny qw[ LoadFile ];
use HTML::TreeBuilder 5 -weak;
use IO::HTML qw[ html_file ];
use Pod::Usage;
use charnames qw[ :full ];
use Scalar::Util qw[ blessed openhandle ];
use Clone::PP qw[ clone ];
use CSS::Tiny;

use constant {
    AREF => ref([]),
    HREF => ref(+{}),
};

my @default_attrs = ( [ from => 'class' ], [ to => '_tag' ] ); # {{{1}}}
my $name_re   = qr/([-\w]+)/;
my %selector_type = (
    _tag  => qr/(?<!\S)$name_re/,
    id    => qr/\#$name_re/,
    class => qr/\.$name_re/,
);

# ERROR {{{1}}}
my $script = basename($0);
sub _error {
    my $msg = shift;
    if ( @_ ) {
        $msg = sprintf $msg, @_;;
    }
    $msg =~ s/\s+/\N{SPACE}/g;
    $msg =~ s/\s*\z/\n/;
    confess "$script: $msg";
}

__PACKAGE__->run(@ARGV) unless caller;

sub run {                                       # {{{1}}}
    my $self = shift;
    my $args = @_ ? \@_ : \@ARGV;
    unless ( ref $self ) {
        my $class = $self;
        $self = $class->new( shift @$args );
    }
    my $tree = shift @$args;
    if ( openhandle $tree ) {
        $tree = $self->get_tree( $tree );
    }
    unless ( ref $tree ) {
        my $fh = $self->get_fh( $tree );
        $tree = $self->get_tree( $fh );
    };
    $self->build_params;
    $self->find_styles;
    $self->change( $tree );
    my $return = shift;
    if ( defined $return ) {
        return $return ? $tree : $self->dump_html($tree);
    }
    print STDOUT $self->dump_html($tree);
}

sub new {                                # {{{1}}}
    my ( $class, $arg ) = @_;
    my $self = ref( $arg ) ? $arg : LoadFile( $arg );
    ref($arg) and $arg = 'parameters';
    AREF eq ref $self and $self = +{ for_elements => $self };
    HREF eq ref $self
      or _error "expected $arg to contain a hashmap or an arraylist";
    for my $key ( qw[ for_elements for_styles ] ) {
        for my $params ( $self->{$key} ) {
            $params ||= [];
            AREF eq ref $params or $params = [$params];
            if ( grep { HREF ne ref $_ } @$params ) {
                _error
                "expected '$key' in $arg to be arraylist of hashmaps or single hashmap";
            }
        } ## end for my $params ( $self...)
    }
    return bless $self => $class;
} ## end sub get_self

sub build_params {    # {{{1}}}
    my ( $self ) = @_;
    for my $params ( @{$self}{qw[ for_elements for_styles ]} ) {
        for my $param ( @$params ) {
            for my $key_attr ( @default_attrs ) {
                my ( $key, $attr ) = @$key_attr;
                for my $data ( $param->{$key} ) {
                    HREF eq ref $data or $data = +{ $attr => $data };
                }
            } ## end for my $key_attr ( @DEFAULT_ATTRS)
          FROM:
            for my $key ( keys %{ $param->{from} } ) {
                for my $val ( $param->{from}{$key} ) {
                    $val =~ s!^/!! or next FROM;
                    my ( $mods ) = $val =~ m!/(\w*)$!;
                    $val = qr/(?$mods:$val)/;
                }
            } ## end FROM: for my $key ( keys %{ $param...})
        } ## end for my $param ( @$params)
    } ## end for my $params ( @{$self...})
    return 1;
} ## end sub build_params


sub find_styles {                               # {{{1}}}
    my ( $self, $css, $for_styles, $for_elems ) = @_;
    $for_styles ||= $self->{for_styles} || return;
    $for_elems = $self->{for_elements} ||= [];
    unless ( blessed $css and $css->isa('CSS::Tiny') ) {
        $css = $self->get_css_data( $css );
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
    PARAMS:
    for my $params ( @$for_styles ) {
        my @found = @styles;
        FROM:
        for my $from ( $params->{from} ) {
            while ( my ( $attr, $val ) = each %$from ) {
                $val = qr/^\Q$val\E$/ unless ref $val;
                @found = grep { $_->{$attr} =~ $val } @found;
                last FROM unless @found;
            }
        }
        next PARAMS unless @found;
        for my $to ( $params->{to} ) {
            for my $found ( @found ) {
                my $from = +{ map { ; $found->{$_} ? ( $_ => $found->{$_}  ) : () } qw[ _tag id class ] };
                push @$for_elems, +{ from => $from, to => $to };
            }
        }
    }
    return $for_elems;
} 

sub get_css_data {                              # {{{1}}}
    my ( $self, $arg ) = @_;
    unless ( $arg ) {
        $arg = $self->{tree} || return;
    }
    if ( ref $arg ) {
        my @styles = $arg->look_down( _tag => 'style' );
        $arg = q{};
        for my $style ( @styles ) {
            $arg .= $self->dump_css( $style );
        }
    } ## end if ( ref $arg )
    $arg =~ s/\Q<!--\E.*?\Q-->\E//g;    # Remove HTML comments
    return CSS::Tiny->read_string( $arg ) || _error CSS::Tiny->errstr;
} ## end sub get_css_data

sub dump_css {                                  # {{{1}}}
    my $style = pop;
    my $elem = $style->clone;
    $elem->tag('div'); # HTML::Element won't dump a style element as text!
    my $css = $elem->as_text;
    return $css;
}



sub change {                                    # {{{1}}}
    my ( $self, $tree ) = @_;
    $tree ||= $self->{tree};
  PARAMS:
    for my $params ( $self->{for_elements} ) {
      PARAM:
        for my $param ( @$params ) {
          FROM:
            for my $from ( $param->{from} ) {
              TO:
                for my $to ( $param->{to} ) {
                    my @elems = $tree->look_down( %$from );
                    @elems or next PARAM;
                  ELEM:
                    for my $elem ( @elems ) {
                      ATTR:
                        while ( my ( $attr => $val ) = each %$to ) {
                            $elem->attr( $attr => $val );
                        }
                    } ## end ELEM: for my $elem ( @elems )
                } ## end TO: for my $to ( $param->{to...})
            } ## end FROM: for my $from ( $param->...)
        } ## end PARAM: for my $param ( @$params)
    } ## end PARAMS: for my $params ( $self->...)
    return $tree;
} ## end sub change

sub get_fh {                                    # {{{1}}}
    my($self, $fn) = @_;
    return $self->{fh} = length($fn) ? html_file($fn) : \*STDIN;
}

sub get_tree {                                  # {{{1}}}
    my( $self, $fh ) = @_;
    $fh ||= $self->{fh};
    $self->{tree} = my $tree = HTML::TreeBuilder->new;
    $tree->ignore_ignorable_whitespace(0);
    $tree->parse_file( $fh );
    return $tree;
}

sub dump_html {                                 # {{{1}}}
    my( $self, $tree ) = @_;
    $tree ||= $self->{tree} || _error "need a tree to dump";
    my $html = $tree->as_HTML( '<>&"', "\N{SPACE}\N{SPACE}", +{} );
    return $html if defined wantarray;
    print STDOUT $html;
}

__END__

=for pandoctext

# NAME

change-html-attrs.pl - change tags and attributes of elements based on their tags and elements

# SYNOPSIS

    perl change-html-attrs.pl CONFIG-YAML [HTML-FILE] >CHANGED-HTML

# DESCRIPTION

`change-html-attrs.pl` is a perl script which changes tags and
attributes of HTML elements based on their tags and elements.

It is especially useful for correcting automatically generated (X)HTML
as output by e.g. by the XHTML export filter of LibreOffice,
which uses `<span>` elements with classes and a corresponding
embedded CSS stylesheet with styles like `.T2 { font-style:italic; }`
rather than `<em>` elements.  I have been told (I'm on Linux) that Apple's TextUtil,
at least when converting from RTF to HTML even replaces headers with
styled `<p>` elements! Clearly these tools reflect the way the data
are represented in the original format, whether ODF XML or RTF too
shallowly.

The script reads a YAML configuration file, then an HTML file,
passed either as a filename or to *stdin*, modifies HTML elements
based on criteria in the configuration file, converts the content
back to HTML and writes it to *stdout*.

# USAGE

The script takes one or two commandline arguments:

1.  (Required.) The name of a YAML file containing
    the replacement criteria configuration.

2.  (Optional.) The name of an HTML file to parse, containing the HTML to modify.

    If the second argument is missing the HTML is read from *stdin*.

    **WARNING:**
    :   If the HTML is not UTF-8 encoded you *must* pass a filename, and charset
        information must be present in the content attribute of a
        `<meta http-equiv="Content-Type"` tag in a possibly
        incomplete HTML document, which will be looked up using
        the "two step" algorithm specified by HTML5. It does not
        look for a BOM. Only the first 1024 bytes of the string
        are checked.

Unfortunately the correspondence between class names and styles
generated automatically by LibreOffice or an RTF writer is not
constant, so one time you may get `.T2 { font-style:italic; }`
and another time you get `.T5 { font-style:italic; }` or some
other random, auto-generated class name for what should be an
`<em>` element. Thus you must visually inspect the style sheet of
every HTML file and write/modify an appropriate configuration
file. It is on my TODO list to make the script analyse the
embedded stylesheet to identify class-to-style correspondances,
although that is currently not yet implemented.

# AUTHOR

Benct Philip Jonsson \<bpjonsson\@gmail.com\>

# COPYRIGHT

Copyright 2015- Benct Philip Jonsson

# LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# SEE ALSO

=for nopandoctext
