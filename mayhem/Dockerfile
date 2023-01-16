# Build Stage
FROM fuzzers/atheris:2.0.7-python3.9

# Install dependencies

ADD . /src
WORKDIR /src
RUN python3 -m pip install .
RUN python3 -m pip install pyexcel-htmlr pyexcel-xls pyexcel-ods pyexcel-xlsx

CMD ["/src/mayhem/fuzz_file.py"]
