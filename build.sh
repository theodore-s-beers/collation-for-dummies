#! /usr/bin/env bash

set -Eeuo pipefail

pandoc \
	--css=reset.css \
	--css=styles.css \
	--highlight-style=zenburn \
	--include-in-header=fonts.html \
	-so index.html \
	index.md

prettier --prose-wrap=always --write .
