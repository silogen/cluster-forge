default:
  @just --list --list-prefix " - "

debug-smelt:
  @devbox run clean
  @LOG_LEVEL=debug go run . smelt
  @rm -rf Library

debug-cast:
  @LOG_LEVEL=debug go run . cast

debug-forge:
  @LOG_LEVEL=debug go run . forge

build:
  @go build

pre-commit:
  @pre-commit run --all-files

clean-all:
  @devbox run clean

gen-doc-vids:
  @vhs docs/demoSmelt.tape -o docs/demoSmelt.gif
  @vhs docs/demoCast.tape -o docs/demoCast.gif
  
