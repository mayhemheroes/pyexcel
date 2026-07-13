#!/usr/bin/env bash
#
# mayhem/build.sh — build the pyexcel Atheris fuzz harness + its standalone reproducer,
# and prepare the project's own test suite. Runs inside the commit image (mayhem/Dockerfile)
# as `mayhem` in /mayhem. Python adaptation of the C/C++ template.
#
# What it does (must be idempotent + air-gapped on re-run — SPEC §6.2 item 9 / §6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent),
#      then install atheris + pytest + pyexcel's runtime deps (lml, pyexcel-io, texttable),
#      the format plugins the harness fuzzes (pyexcel-xls/-xlsx/-ods/-htmlr) and the test-suite
#      deps (flask, SQLAlchemy, pyexcel-text, chardet, psutil) OFFLINE from that wheelhouse into
#      a fixed site dir on PYTHONPATH. The first (CI, online) build fills the wheelhouse; the
#      air-gapped PATCH re-run resolves entirely from it (pip --no-index --find-links). pyexcel
#      itself is exercised as its editable source tree (repo root on PYTHONPATH).
#   2. Compile launcher.c -> the ELF Mayhem target `pyexcel_fuzzer` (Atheris is a Python
#      script; Mayhem needs an ELF cmd, and the gate needs DWARF < 4 — hence a compiled wrapper).
#   3. Build the same launcher as the standalone (run-once) reproducer `pyexcel_fuzzer-standalone`.
#   4. Compile the pytest ELF runner wrapper `pyexcel_run_tests` (so the sabotage oracle bites).
#
# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). We only need
# DEBUG_FLAGS here (the launcher is a thin C exec wrapper — sanitizing it would just instrument the
# wrapper, not the fuzzed Python; Atheris instruments the pyexcel library itself at import time).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) ──
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
# lml resolves multi-plugin file types (xlsx/xlsm claimed by BOTH pyexcel-xls and pyexcel-xlsx) by
# FIRST-scanned module, and pkgutil scan order follows sys.path — so pyexcel-xlsx lives in a
# priority dir listed first on PYTHONPATH. Otherwise xlsx can route to pyexcel-xls' xlrd-1.2 path,
# which is broken on Python >= 3.9 (ElementTree.getiterator removed).
SITE_PRI="$PY_PREFIX/site-priority"
mkdir -p "$WHEELHOUSE" "$SITE" "$SITE_PRI"

PY="$(command -v python3)"

# 1) Wheelhouse: download every runtime/test dependency ONCE (online). On the air-gapped re-run the
#    directory is already populated, so pip never reaches the network. atheris ships a prebuilt
#    manylinux wheel for this CPython. pytest runs pyexcel's own suite (tests/ + doctests).
PKGS=(
  atheris pytest
  # build backend for sdist-only deps (pyexcel-text ships no wheel) — must resolve offline too
  setuptools wheel
  # pyexcel runtime deps (setup.py INSTALL_REQUIRES)
  lml "pyexcel-io>=0.6.2" texttable
  # format plugins the file-parse harness exercises
  "pyexcel-xls<=0.6.2" "pyexcel-xlsx>=0.4.1" pyexcel-ods pyexcel-htmlr
  # upstream test-suite deps (tests/requirements.txt, sans lint/coverage tooling)
  chardet flask SQLAlchemy "pyexcel-text>=0.2.0" pyexcel-pygal psutil
)
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*.whl')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install the deps into the fixed site dir, OFFLINE from the wheelhouse. --no-index +
#    --find-links guarantees no PyPI access (works on the air-gapped re-run). Idempotent: once the
#    site dir holds atheris+pytest we SKIP the reinstall. pyexcel itself stays the editable source
#    tree (repo root on PYTHONPATH) so a PATCH agent's edits under pyexcel/ take effect with no
#    reinstall.
if "$PY" -c "import os,glob,sys; sys.exit(0 if (glob.glob(os.path.join('$SITE','atheris*')) and glob.glob(os.path.join('$SITE','pytest*'))) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${PKGS[@]}"
fi
if "$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$SITE_PRI','pyexcel_xlsx*')) else 1)"; then
  echo ">> priority site already populated — skipping"
else
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE_PRI" --no-deps pyexcel-xlsx
fi

# pyexcel is a top-level package at the repo root, so the repo root itself goes on PYTHONPATH.
PYRUN="$SITE_PRI:$SITE:$SRC"

# Record the site dir + interpreter for test.sh / the launcher to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, pyexcel, pytest, xlrd.biffh; print("imports OK: pyexcel", pyexcel.__version__)'

# 3) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
#    The launcher execs $PY on the harness; PYTHONPATH is baked into the env the binary inherits
#    at run time (the Dockerfile sets ENV PYTHONPATH), so the Python side finds atheris + pyexcel.
HARNESS="$SRC/mayhem/fuzz_file.py"
echo ">> compiling pyexcel_fuzzer (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/pyexcel_fuzzer"
# The standalone reproducer is the same launcher: libFuzzer runs a single input file once when the
# harness is given a file path (no fuzzing loop), which is exactly the run-once reproducer contract.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/pyexcel_fuzzer-standalone"

# 4) The pytest oracle runs through a compiled NON-system ELF wrapper so the gate's anti-reward-hack
#    sabotage check (which neuters non-system binaries to exit(0)) actually bites the suite — a
#    test.sh that shelled straight to the /usr/bin python would be spared and look reward-hackable.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/pyexcel_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/pyexcel_fuzzer" "$SRC/pyexcel_fuzzer-standalone" "$SRC/pyexcel_run_tests"
