default:
  @just --list --list-prefix " - "

demo:
  @echo "now I'm running the demo"

debug:
  @LOG_LEVEL=debug go run .

build:
  @go build

pre-commit:
  @pre-commit run --all-files