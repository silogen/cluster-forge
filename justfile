default:
  @just --list --list-prefix " - "

demo:
  @echo "now I'm running the demo"

debug-smelt:
  @LOG_LEVEL=debug go run . -smelt
  @rm -rf Library
  @stty sane 2>/dev/null

debug-cast:
  @LOG_LEVEL=debug go run . -cast
  @stty sane 2>/dev/null

debug-forge:
  @LOG_LEVEL=debug go run . -forge
  @stty sane 2>/dev/null

build:
  @go build

pre-commit:
  @pre-commit run --all-files
