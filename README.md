NAME
====

change-html-attrs.pl - change tags and attributes of elements based on their tags and elements

SYNOPSIS
========

    perl change-html-attrs.pl -c CONFIG-YAML [OPTIONS] [HTML-FILE...]

DESCRIPTION
===========

`change-html-attrs.pl` is a perl program which changes tags and attributes of HTML elements based on their tags and elements.

The program reads a YAML configuration file, then an HTML file, passed either as a filename or to *stdin*, modifies HTML elements based on criteria in the configuration file, converts the content back to HTML and writes it to *stdout*.

It is especially useful for correcting automatically generated (X)HTML as output by e.g. by the XHTML export filter of LibreOffice, which uses `<span>` elements with classes and a corresponding embedded CSS stylesheet with styles like `.T2 { font-style:italic; }` rather than `<em>` elements. I have been told (I'm on Linux) that Apple's TextUtil, at least when converting from RTF to HTML even replaces headers with styled `<p>` elements! Clearly these tools reflect the way the data are represented in the original format, whether ODF XML or RTF too shallowly.

Unfortunately the correspondence between class names and styles generated automatically by LibreOffice or an RTF writer is not constant, so one time you may get `.T2 { font-style:italic; }` and another time you get `.T5 { font-style:italic; }` or some other random, auto-generated class name for what should be an `<em>` element. To work around this you can use CSS property names and values as search criteria, and if the HTML file contains any `<style>` elements these will be analysed to identify classes, ids and/or tags corresponding to the specified CSS attributes and matching elements will be modified accordingly.

OPTIONS
=======

-   `-c`, `-y`, `--config`, `--yaml` *FILE*

    The YAML config file to use. See ["The YAML config file"][] for its structure. This argument is required.

-   `-C`, `--css` *FILE* (Repeatable)

    A CSS stylesheet file to use for mapping CSS styles to HTML attributes, in addition to or instead of style sheet(s) embedded in the HTML file(s). This option can be given more than once for multiple files.

-   `-b`, `--body-only`

    Print out only the `<body>` of the HTML documents, with the `body` element name replaced by `div`.

    When used in conjunction with `--modify-in-place` this *will* lead to loss of any information in the `<head>`!

-   `-i`, `--modify-in-place` [*.EXTENSION*]

    Write the modified HTML back to the original file after modification. The modified content will be UTF-8 encoded regardless of the original encoding and the `charset` attribute of any `<meta http-equiv="Content-Type">` element will have been updated accordingly.

    When *.EXTENSION* is present the original file will be backed up to a file with *.EXTENSION* added to the filename.

    If possible it is recommended to keep your files in a local git repository and do the in-place modification in a fresh branch. If anything goes wrong you can do `git reset --hard` and return everything to the state before modification. When all is done and well you can merge the modification branch back into your main branch.

-   `-s`, `--stdout`

    If both this option and `--modify-in-place` are true modified HTML will be written to *stdout* as well as to files.

    When `--modify-in-place` is false `--stdout` is implied and all output will go to *stdout*.

-   `-h`, `--help`

    Show the help text.

-   `-m`, `--man`

    Show the entire manual.

USAGE
=====

(For the format of the YAML configuration file see below!)

Apart from the `--config YAML_FILE` option which *must* be present the program takes any number of HTML file names as arguments, or reads a single file from *stdin*.

The files are processed separately but if the `--modify-in-place` option is not used they are all written to *stdout*.

When doing this the `--body-only` option is useful as it causes the `<body>` of each input document, if any, to be output as a `<div>`.

Each input file is scanned for `<style>` elements, which if found are processed against the `for_styles:` section of the config file, using any resulting conversions in the processing of the current document, in addition to (actually before) the conversions given in the `for_elements:` section of the config file and any conversions derived from CSS files given with the `--css` option.

-   **WARNING:**

    If the HTML is not UTF-8 encoded you *must* pass a filename, as second argument and charset information must be present in the content attribute of a `<meta http-equiv="Content-Type"` tag in a possibly incomplete HTML document, which will be looked up using the "two step" algorithm specified by HTML5. It does not look for a BOM. Only the first 1024 bytes of the string are checked.

The modified document will be converted back to HTML and written to *stdout* in UTF-8 encoding.

The YAML configuration file
---------------------------

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

For the supported subset of YAML syntax see <https://metacpan.org/pod/YAML::Tiny#YAML-TINY-SPECIFICATION>

The structure of the configuration file is described below.

### `for_styles:` and `for_elements:`

The top level is a mapping with at least one of the keys `for_styles:` and `for_elements`, each with a list as value. If the top level is a list it is assigned to `for_elements:`

Each of the values of `for_styles:` and `for_elements` is a list of mappings with two keys `from:` (the search criteria) and `to:` (the replacement values), each with a mapping as value.

### `from:`

The `from:` mapping of the `for_elements:` list items have HTML attribute names as keys and plain strings or strings containing Perl regular expressions, or as explicitly null values specified with `~`, e.g. `href: ~`.

#### Regular expressions

Regular expressions are entered as normal strings and identified as regexes by a leading forward slash and an optional trailing slash followed by regular expression modifier letters: `/REGEX/MODIFIERS`, e.g. `/^P\d+$/i` which matches a string consisting of a `P` or `p` followed by one or more digits, `/^P\d+$/` being the format of an automatical paragraph style class in the output of LibreOffice's XHTML exporter. Note that strings containing regular expressions should normally be enclosed in single quotes to prevent that punctuation characters inside them are interpreted as YAML metacharacters.

If you are unfamiliar with regular expressions in general or Perl regular expressions in particular you can find increasingly in-depth information with the `perldoc` command line program:

    $ perldoc perlrequick

    $ perldoc perlretut

    $ perldoc perlre

For the valid trailing modifiers see:

    $ perldoc -f qr

#### Element selection

The search criteria select all elements where all the criteria in the `from:` mapping match the corresponding HTML attributes:

    from:
        _tag:   span
        class:  '/\bfoo\b/'

selects all `<span>` elements with a class `foo`. Non-span elements or elements without a `foo` class are not selected.

The following rules apply for attribute value matching:

-   Plain strings

    Must match exactly, i.e. the attribute value must be that exact string.

-   Regular expressions

    The attribute value must match the regular expression. If you don't want to match a substring use the beginning-of-string and end-of-string anchors `^` and `$`.

-   Null search criterion values

    The attribute must not be present in the element; thus `href: ~` will match elements without any `href` attribute.

    Note that there is a subtle difference between an null value and an empty string as search criterion values: the empty string will select elements where the value of the attribute in question *is* an empty string, while an null value will select elements where the attribute in question is missing.

-   The key `_tag:`

    The search criterion key `_tag:`, with a leading underscore, matches the *element name* rather than an attribute. Thus `_tag: span` will select `<span>` elements.

-   Classes

    Remember that classes are stored in a single string separated by whitespace. To match a single class enclose use a regular expressionand enclose the class name with `\b` anchors, or if the element should have only a single class with `^` and `$` anchors.

#### In `for_styles:`

The `from:` mappings of the `for_styles:` section are similar, except that

1.  You can use CSS attribute names and values as search criteria. Thus for example `font-family: '/Courier'` will match elements to which a style rule specifying Courier or Courier New as font-family apply.
2.  The only HTML attributes you can match are `id`, `class` and the element-name 'attribute' `_tag`, namely as inferred from the CSS selectors, which are matched against the following regular expressions:

        _tag  : /(?<!\S)([-\w]+)/
        id    : /\#([-\w]+)/
        class : /\.([-\w]+)/

-   **NOTE:**

    Style matching works by matching the `from:` criteria of the `for_styles` section against CSS style rules embedded in the HTML document and constructing `for_elements` criteria based on their selectors.

    Child selectors like `p.foo span.bar` do not work. Such rules are simply ignored. Comma-separated selectors like `p.foo, span.bar` *do* work, but all other selectors containing whitespace are ignored.

### `to:`

`to:` mappings simply specify string attribute values which should replace the old attribute values -- or the element name; the `_tag` 'attribute' is supported! A null value delete the attribute, so `class: ~` will remove the `class` attribute.

#### For Perl users

There is one possible key which does not just set an attribute string value, distinguished by being uppercase:

-   `CALL:`

    A list of lists, where the first item of the inner lists should be the name of an [HTML::Element][] method to call on the object representing the element and the following items are arguments to the method if any.

    As a special shortcut you can give a single method name like `CALL: delete` instead of a list of lists.

    Please note that this feature has not been extensively tested: the only forms I have ever actually used are `CALL: delete` and `CALL: replace_with_content`! These are arguably the most useful ones.

AUTHOR
======

Benct Philip Jonsson <bpjonsson@gmail.com>

COPYRIGHT
=========

Copyright 2015- Benct Philip Jonsson

LICENSE
=======

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

  ["The YAML config file"]: #the-yaml-config-file
  [HTML::Element]: https://metacpan.org/pod/HTML::Element
