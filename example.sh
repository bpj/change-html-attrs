#!/bin/bash

perldoc -MPod::Simple::XHTML -F README.pod > pod.xhtml
pandoc pod.xhtml -o example.odt
libreoffice --headless --convert-to xhtml example.odt
tidy example.xhtml >tidy.xhtml
perl change-html-attrs.pl -c example.yaml example.xhtml >example-output.xhtml
