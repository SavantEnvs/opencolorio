#!/usr/bin/env bash
#
# mayhem/build.sh — build OpenColorIO (sanitized, static) + the fuzz harnesses, and the unit-test oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Pinned dependency sources are baked into the image by the Dockerfile (air-gapped re-runs).
DEPS_SRC=/opt/deps-src
FUZZ_DIR="$SRC/build-mayhem-fuzz"      # gitignored by upstream's `build*` rule (SPEC §6.2 item 16)
TEST_DIR="$SRC/build-mayhem-test"

# build_deps <prefix> <build-dir> <extra C/C++ flags>: static yaml-cpp + minizip-ng.
build_deps() {
  local prefix="$1" bdir="$2" flags="$3"
  cmake -S "$DEPS_SRC/yaml-cpp" -B "$bdir/yaml-cpp" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF -DYAML_BUILD_SHARED_LIBS=OFF \
    -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF -DYAML_CPP_BUILD_CONTRIB=OFF
  cmake --build "$bdir/yaml-cpp" -j"$MAYHEM_JOBS" && cmake --install "$bdir/yaml-cpp"

  # Same option set OCIO's own ExternalProject uses for minizip-ng (zlib only).
  cmake -S "$DEPS_SRC/minizip-ng" -B "$bdir/minizip-ng" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF \
    -DMZ_OPENSSL=OFF -DMZ_LIBBSD=OFF -DMZ_BUILD_TESTS=OFF -DMZ_COMPAT=OFF -DMZ_BZIP2=OFF \
    -DMZ_LZMA=OFF -DMZ_LIBCOMP=OFF -DMZ_ZSTD=OFF -DMZ_PPMD=OFF -DMZ_PKCRYPT=OFF -DMZ_WZAES=OFF \
    -DMZ_SIGNING=OFF -DMZ_ZLIB=ON -DMZ_ICONV=OFF -DMZ_FETCH_LIBS=OFF -DMZ_FORCE_FETCH_LIBS=OFF
  cmake --build "$bdir/minizip-ng" -j"$MAYHEM_JOBS" && cmake --install "$bdir/minizip-ng"
}

# Compilers come from the exported CC/CXX env (not -DCMAKE_*_COMPILER): a re-run on an existing build
# dir would otherwise see "clang++" != the cached "/usr/bin/clang++" and wipe the cache mid-configure.
# OCIO options shared by the fuzz and test builds: no apps/python/docs/GPU tests, never fetch deps.
OCIO_COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release
  -DOCIO_BUILD_APPS=OFF -DOCIO_BUILD_PYTHON=OFF -DOCIO_BUILD_DOCS=OFF -DOCIO_BUILD_GPU_TESTS=OFF
  -DOCIO_BUILD_OPENFX=OFF -DOCIO_BUILD_JAVA=OFF -DOCIO_WARNING_AS_ERROR=OFF
  -DOCIO_INSTALL_EXT_PACKAGES=NONE)

# 1+2) Fuzz build: sanitized + SanCov-instrumented static OpenColorIO (+ deps), then the harnesses.
# -fno-sanitize=enum (only that UBSan check): bundled sampleicc loads raw ICC tag signatures straight
# into enums (iccProfileReader.h:644/707), so every ICC input with an unknown tag would abort the
# target before reaching real code (see fuzz_filetransform/known-findings/). ASan and the rest of
# UBSan stay on and halting.
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize=enum -fsanitize=fuzzer-no-link"
build_deps "$FUZZ_DIR/deps" "$FUZZ_DIR/deps-build" "$FUZZ_FLAGS"

cmake -S "$SRC" -B "$FUZZ_DIR/ocio" "${OCIO_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=OFF -DOCIO_BUILD_TESTS=OFF \
  -DCMAKE_PREFIX_PATH="$FUZZ_DIR/deps" -DCMAKE_INSTALL_PREFIX="$FUZZ_DIR/inst" \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build "$FUZZ_DIR/ocio" -j"$MAYHEM_JOBS"
cmake --install "$FUZZ_DIR/ocio"

# LeakSanitizer off for every fuzz/standalone binary (SPEC §6.2 item 15).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_DIR/lsan_off.o"

cmake -S "$SRC/mayhem/harness" -B "$FUZZ_DIR/harness" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DLSAN_OFF_OBJ="$FUZZ_DIR/lsan_off.o" \
  -DCMAKE_PREFIX_PATH="$FUZZ_DIR/inst;$FUZZ_DIR/deps" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake --build "$FUZZ_DIR/harness" -j"$MAYHEM_JOBS"
for t in fuzz_config fuzz_filetransform fuzz_ocioz; do
  cp "$FUZZ_DIR/harness/$t" "/mayhem/$t"
  cp "$FUZZ_DIR/harness/$t-standalone" "/mayhem/$t-standalone"
done

# 3) Oracle build: upstream's own unit tests with NORMAL flags (no sanitizer, no -gdwarf-3).
build_deps "$TEST_DIR/deps" "$TEST_DIR/deps-build" ""
cmake -S "$SRC" -B "$TEST_DIR/ocio" "${OCIO_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=ON -DOCIO_BUILD_TESTS=ON \
  -DCMAKE_PREFIX_PATH="$TEST_DIR/deps" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_DIR/ocio" -j"$MAYHEM_JOBS" --target test_cpu_exec
