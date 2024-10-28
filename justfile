default:
  @just --list --list-prefix " - "

demo:
  @echo "now I'm running the demo"

debug-smelt:
  @LOG_LEVEL=debug go run . -smelt
  @rm -rf Library

debug-cast:
  @LOG_LEVEL=debug go run . -cast

debug-forge:
  @LOG_LEVEL=debug go run . -forge

build:
  @go build

pre-commit:
  @pre-commit run --all-files

clean-all:
  @sh scripts/clean.sh