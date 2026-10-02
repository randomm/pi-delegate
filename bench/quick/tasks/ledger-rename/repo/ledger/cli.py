import argparse
import sys

from .report import render
from .store import Store


def main(argv=None, stdin=None) -> int:
    p = argparse.ArgumentParser(prog="ledger")
    p.add_argument("command", choices=["report"])
    args = p.parse_args(argv)
    store = Store()
    store.load((stdin or sys.stdin).read())
    if args.command == "report":
        print(render(store))
    return 0
