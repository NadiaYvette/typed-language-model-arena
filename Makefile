# Code-quality gates for the typed-language-model-arena.
# .git/hooks/pre-commit calls `make pre-commit`; run `make check` for the full suite.

HS_FILES := $(shell find . -name '*.hs' -not -path './dist-newstyle/*' -not -path './.git/*' | sort)
CABAL_FILES := $(shell find . -name '*.cabal' -not -path './dist-newstyle/*' -not -path './.git/*' | sort)

.PHONY: help fmt fmt-check lint cabal-fmt cabal-fmt-check wall check pre-commit

help:
	@echo "fmt            Reformat all .hs files in place (fourmolu)"
	@echo "fmt-check      Fail if any .hs file is not fourmolu-formatted"
	@echo "lint           Run hlint over the tree"
	@echo "cabal-fmt      Reformat all .cabal files in place"
	@echo "cabal-fmt-check Fail if any .cabal file is not cabal-fmt-formatted"
	@echo "wall           cabal build all (GHC -Wall via package ghc-options)"
	@echo "check          fmt-check + lint + cabal-fmt-check + wall"
	@echo "pre-commit     Fast gates used by .git/hooks/pre-commit (no build)"

fmt:
	fourmolu -i $(HS_FILES)

fmt-check:
	fourmolu --mode check $(HS_FILES)

lint:
	hlint .

cabal-fmt:
	cabal-fmt -i $(CABAL_FILES)

cabal-fmt-check:
	cabal-fmt --check $(CABAL_FILES)

wall:
	cabal build all

check: fmt-check lint cabal-fmt-check wall

pre-commit: fmt-check lint cabal-fmt-check
