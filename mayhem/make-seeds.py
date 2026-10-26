#!/usr/bin/env python3
"""Regenerate the starter seeds under mayhem/<target>/testsuite/ from OCIO's own test data.

fuzz_filetransform seeds are `<ext index><flags>` + file bytes; the index is into kExtensions
in harness/fuzz_filetransform.cc (keep both lists in sync).
"""
import pathlib, shutil

root = pathlib.Path(__file__).resolve().parent.parent
files = root / "tests/data/files"
EXT = [".cdl", ".3dl", ".cube", ".cc", ".clf", ".ctf", ".lut", ".csp", ".look", ".mga", ".m3d",
       ".itx", ".spi1d", ".spi3d", ".cub", ".ccc", ".vf", ".spimtx", ".icc", ".icm", ".pf"]
MAX = 24 * 1024
PER_EXT = 10


def reset(name):
    d = root / "mayhem" / name / "testsuite"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    return d


d = reset("fuzz_config")
cfgs = [p for p in list(files.rglob("*.ocio")) + list(files.rglob("*.yaml")) + list(files.rglob("*.ociom"))
        if p.stat().st_size <= MAX]
cfgs += [root / "docs/configurations/ocio-v2_demo.ocio"]
cfgs += sorted((root / "src/OpenColorIO/builtinconfigs/configs").glob("cg-config-v[14]*.ocio"))
for p in cfgs:
    (d / f"{p.parent.name}__{p.name}").write_bytes(p.read_bytes())

d = reset("fuzz_filetransform")
for idx, ext in enumerate(EXT):
    cands = sorted((p for p in files.rglob("*" + ext) if p.is_file() and p.stat().st_size <= MAX),
                   key=lambda p: (p.stat().st_size, p.name))
    # spread over the size range rather than taking only the smallest files
    step = max(1, len(cands) // PER_EXT)
    for p in cands[::step][:PER_EXT]:
        for flags in (0x04, 0x07):
            if flags == 0x07 and ext not in (".ctf", ".clf", ".cube", ".spi1d", ".spi3d", ".csp"):
                continue
            (d / f"{ext[1:]}_{flags:02x}_{p.name}").write_bytes(bytes([idx, flags]) + p.read_bytes())

d = reset("fuzz_ocioz")
for p in files.rglob("*.ocioz"):
    if p.stat().st_size <= 4 * MAX:
        (d / f"{p.parent.name}__{p.name}").write_bytes(p.read_bytes())
