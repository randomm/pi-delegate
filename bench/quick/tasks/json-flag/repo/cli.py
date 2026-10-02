import argparse
import sys

from stats import summarize


def main(argv=None):
    p = argparse.ArgumentParser(prog="stats")
    p.add_argument("numbers", nargs="+", type=float)
    args = p.parse_args(argv)
    s = summarize(args.numbers)
    for k, v in s.items():
        print(f"{k}: {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
