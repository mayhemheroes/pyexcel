#!/usr/bin/env python3
import csv
from zipfile import BadZipFile

import atheris
import sys

import xlrd.biffh

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
