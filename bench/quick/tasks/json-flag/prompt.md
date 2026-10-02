Add a `--json` flag to the CLI in cli.py: with it, print the summary as a
single JSON object (keys count, min, max, mean; sorted keys) instead of the
`key: value` lines. Default output must stay unchanged. Also make
`python cli.py` with no numbers exit with status 2 (argparse already does
that - just keep it). Standard library only. Do not commit.
