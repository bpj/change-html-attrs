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
                        CALLS:
                        if ( my $calls = $to->{CALL} ) {
                            CALL:
                            for my $call ( @$calls ) {
                                my( $method, @args ) = @$call;
                                next CALL unless $method;
                                $elem->$method( @args );
                            }
                        }
                        delete local $to->{CALL};
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

The script reads a YAML configuration file, then an HTML file,
passed either as a filename or to *stdin*, modifies HTML elements
based on criteria in the configuration file, converts the content
back to HTML and writes it to *stdout*.

It is especially useful for correcting automatically generated
(X)HTML as output by e.g. by the XHTML export filter of
LibreOffice, which uses `<span>` elements with classes and a
corresponding embedded CSS stylesheet with styles like
`.T2 { font-style:italic; }` rather than `<em>` elements. I have
been told (I'm on Linux) that Apple's TextUtil, at least when
converting from RTF to HTML even replaces headers with styled
`<p>` elements! Clearly these tools reflect the way the data are
represented in the original format, whether ODF XML or RTF too
shallowly.

Unfortunately the correspondence between class names and styles
generated automatically by LibreOffice or an RTF writer is not
constant, so one time you may get `.T2 { font-style:italic; }`
and another time you get `.T5 { font-style:italic; }` or some
other random, auto-generated class name for what should be an
`<em>` element. To work around this you can use CSS property
names and values as search criteria, and if the HTML file
contains any `<style>` elements these will be analysed to
identify classes, ids and/or tags corresponding to the specified
CSS attributes and matching elements will be modified
accordingly.

# USAGE

The script takes one or two commandline arguments:

1.  (Required.) The name of a YAML file containing
    the replacement criteria configuration.

2.  (Optional.) The name of an HTML file to parse, containing the HTML to modify.

    If the second argument is missing the HTML is read from *stdin*.

    **WARNING:**
    :   If the HTML is not UTF-8 encoded you *must* pass a filename,
        as second argument and charset information must be
        present in the content attribute of a
        `<meta http-equiv="Content-Type"` tag in a possibly
        incomplete HTML document, which will be looked up using
        the "two step" algorithm specified by HTML5. It does not
        look for a BOM. Only the first 1024 bytes of the string
        are checked.

The modified document will be converted back to HTML and written to *stdout* in UTF-8 encoding.

# The YAML configuration file

The YAML configuration file should look something like this:

```
---
for_styles:
# Inline code
- from:   # Search criteria
    class: '/^T\d+$'          # Leading / indicates regular expression
    font-family: '/Courier'
  to:     # replacement values
    _tag: code
    class: ~      # Undefined replacement value: delete the attribute
- from:
    class: '/^T\d+$'
    font-style: '/italic'
  to:
    _tag: em
- from:
    class: '/^T\d+$'
    font-weight: '/bold'
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
# Delete A elements without an href attribute
- from:
    _tag: a
    href: ~     # Undefined search value: the attribute must not exist
  to:
    CALL: delete    # Call a method on the HTML::Element object!
# Delete classes from header elements
- from:
    _tag: '/^h[1-6]$'
  to:
    class: ~
```

For the supported subset of YAML syntax see
<https://metacpan.org/pod/YAML::Tiny#YAML-TINY-SPECIFICATION>

The structure of the configuration file should be as follows:

*   The top level is a mapping with at least one of the keys
    `for_styles:` and `for_elements`, each with a list as value.
    If the top level is a list it is assigned to `for_elements:`

*   Each of the values of `for_styles:` and `for_elements` is a
    list of mappings with two keys `from:` (the search
    criteria) and `to:` (the replacement values), each with a
    mapping as value.

*   The `from:` mapping of the `for_elements:` list items have
    HTML attribute names as keys and plain strings or strings containing
    Perl regular expressions, or as explicitly undefined values specified with
    `~`, e.g. `href: ~`. 
    
    Regular expressions are entered as normalstrings and
    identified as regexes by a leading
    forward slash and an optional trailing slash followed by
    regular expression modifier letters: `/REGEX/MODIFIERS`, e.g.
    `/^P\d+$/i` which matches a string consisting of a `P` or
    `p` followed by one or more digits, `/^P\d+$/` being the
    format of an automatical paragraph style class in the output
    of LibreOffice's XHTML exporter. Note that strings containing
    regular expressions
    should normally be enclosed in single quotes to prevent that
    punctuation characters inside them are interpreted as YAML metacharacters.
    
    If you are unfamiliar with
    regular expressions in general or Perl regular expressions
    in particular you can find increasingly in-depth information
    with the `perldoc` command line program:

        $ perldoc perlrequick

        $ perldoc perlretut

        $ perldoc perlre

    For the valid trailing modifiers see:

        $ perldoc -f qr

*   The search criteria select all elements where all the criteria
    in the `from:` mapping match the corresponding HTML attributes:

    ```
    from:
        _tag:   span
        class:  '/\bfoo\b/'
    ```

    selects all `<span>` elements with a class `foo`.  Non-span elements
        or elements without a `foo` class are not selected.

    The following rules apply for attribute value matching

    Plain strings
    ~   Must match exactly, i.e. the attribute value must be that exact string.

    Regular expressions
    ~   The attribute value must match the regular expression.
        If you don't want to match a substring use the beginning-of-string
        and end-of-string anchors `^` and `$`.

    Undefined search criterion values
    ~   The attribute must not be present in the element; thus `href: ~`
        will match elements without any `href` attribute.

        Note that there is a subtle difference between an undefined value
            and an empty string as search criterion values: the empty string
        will select elements where the value of the attribute in question
        *is* an empty string, while an undefined value will select elements
        where the attribute in question is missing.

    The key `_tag:`
    ~   The search criterion key `_tag:`, with a leading underscore,
        matches the *element attribute name* rather than an attribute.
        Thus `_tag: span` will select `<span>` elements.

    Classes
    ~   Remember that classes are stored in a single string separated by whitespace.
        To match a single class enclose use a regular expressionand enclose the 
        class name with `\b` anchors, or if the element
        should have only a single class with `^` and `$` anchors.

*   The `from:` mappings of the `for_styles:` section are similar,
    except that

    1.  You can use CSS attribute names and values as search criteria.
        Thus for example `font-family: '/Courier'` will match elements
        to which a style rule specifying Courier or Courier New as font-family apply.

    2.  The only HTML attributes you can match are `id`, `class` and the
        element-name 'attribute' `_tag`, namely as inferred from the CSS selectors,
        which are matched against the following regular expressions:

            _tag  : /(?<!\S)([-\w]+)/
            id    : /\#([-\w]+)/
            class : /\.([-\w]+)/

    **NOTE:**
    ~   Style matching works by matching the `from:` criteria of the `for_styles`
        section against CSS style rules embedded in the HTML document and constructing
        `for_elements` criteria based on their selectors.

    ~   Child selectors like `p.foo span.bar` do not work. Such
        rules are simply ignored. Comma-separated selectors like
        `p.foo, span.bar` *do* work, but all other selectors
        containing whitespace are ignored.

*   `to:` mappings simply specify string attribute values which should replace the old
    attribute values -- or the element name; the `_tag` 'attribute' is supported!

    The exception is the key `CALL:` (note the upper case!): its value should be
    a list of lists, where the first item of the inner lists should be the name
    of an [](cpan:HTML::Element) method to call on the object representing the
    element and the following items are arguments to the method if any. 
    As a special shortcut you can give a single method name like `CALL: delete`
    instead of a list of lists.  Please note that this feature has not been
    extensively tested: the only forms I have ever actually used are
    `CALL: delete` and `CALL: replace_with_content`! These are arguably the
    most useful ones. A way to call `replace_with` in a meaningful way,
    where you can insert a clone of the original method or its content list,
    is on the TODO list.

        
# AUTHOR

Benct Philip Jonsson \<bpjonsson\@gmail.com\>

# COPYRIGHT

Copyright 2015- Benct Philip Jonsson

# LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# SEE ALSO

=for nopandoctext
