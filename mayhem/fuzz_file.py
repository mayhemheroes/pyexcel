#!/usr/bin/env python3
"""Atheris fuzz harness for pyexcel: parse fuzzer-chosen spreadsheet content
in every supported file format via pyexcel.get_sheet (ported from the
original mayhemheroes `file-parse` target)."""
import contextlib
import csv
import os
from zipfile import BadZipFile

import atheris
import sys

import xlrd.biffh

# pyexcel transitively imports hundreds of modules, so a bare instrument_imports() emits an
# "INFO: Instrumenting ..." line per module — enough preamble to push the libFuzzer banner out
# of Mayhem's smoke-test output window (the run is then rejected as "did not run / output did
# not match the libFuzzer format"). Silence the banner; libFuzzer itself writes to fd 2 from
# native code, which a sys-level redirect does not touch.
with open(os.devnull, "w") as _devnull, \
        contextlib.redirect_stdout(_devnull), contextlib.redirect_stderr(_devnull):
    with atheris.instrument_imports():
        import pyexcel

supported_file_types = [
    'csv',
    'tsv',
    'csvz',
    'tsvz',
    'xls',
    'xlsx',
    'xlsm',
    'ods',
    'html',
]


@atheris.instrument_func
def TestOneInput(data):
    fdp = atheris.FuzzedDataProvider(data)

    file_ty = fdp.PickValueInList(supported_file_types)

    try:
        pyexcel.get_sheet(file_type=file_ty, file_content=fdp.ConsumeBytes(fdp.remaining_bytes()))
    except (BadZipFile, UnicodeDecodeError, xlrd.biffh.XLRDError, csv.Error):
        return -1
    except OSError as e:
        if 'Unrecognized' not in str(e):
            raise
    except ValueError as e:
        if 'XML' not in str(e):
            raise


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
