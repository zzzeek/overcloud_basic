#!/usr/bin/python

import argparse
import re
import sys

if sys.version_info.major == 3:
    import configparser
else:
    import ConfigParser as configparser


def main(argv=None):
    parser = argparse.ArgumentParser(description="merges conf files in order")

    parser.add_argument(
        "-e",
        action="append",
        help="Substitution variable, e.g. -e 'my_ip=172.18.0.10' -e 'foo=bar'",
    )
    parser.add_argument(
        "src",
        type=str,
        nargs='+',
        help="Source files, highest precedence is given to the leftmost file",
    )
    parser.add_argument("dest", type=str, help="Destination file")
    args = parser.parse_args()

    environment_defaults = {
        m.group(1): m.group(2)
        for m in [
            re.match(r'([\w_]+)\s*=\s*(.*)', env)
            for env in args.e
        ] if m
    }

    config = configparser.ConfigParser(environment_defaults)

    for src_file in reversed(args.src):
        config.read(src_file)

    import pdb
    pdb.set_trace()
    with open(args.dest, "w") as file_:
        config.write(file_)


if __name__ == "__main__":
    main()
