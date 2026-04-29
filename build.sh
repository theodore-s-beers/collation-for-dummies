#! /usr/bin/env bash

set -Eeuo pipefail

pandoc \
	--css=reset.css \
	--css=styles.css \
	--syntax-highlighting=breezeDark \
	--include-in-header=fonts.html \
	--include-in-header=meta.html \
	-so index.html \
	index.md

oxfmt
