#!/usr/bin/env python3
"""Defer Go's unused 32 MiB FIPS scratch buffer on low-memory QDC507.

Go 1.26/1.27 link this buffer into BSS even when FIPS mode is off. QDC507's
Linux 3.18 overcommit heuristic rejects that ELF at exec (SIGSEGV), before
GOMEMLIMIT can apply. Change allocation timing only, using a build overlay;
never modify the installed SDK, entropy source or cryptographic algorithms.
Unknown SDK source revisions fail closed and need a reviewed adaptation.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def prepare(destination):
    root = Path(subprocess.check_output(["go", "env", "GOROOT"], text=True).strip())
    original = root / "src/crypto/internal/fips140/drbg/entropy_fips140.go"
    data = original.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    reviewed = {
        # Official Go 1.26.3 and Go 1.27.0, respectively.
        "f306dbe6349f3d3dbf0fd512f3921263e5ca2d52a533aca410531e73ef1e2c7d",
        "bd3c834a29e31c93e56d81da54d4a874561814a86550de1456c8d6d40a9c5fda",
    }
    if digest not in reviewed:
        raise SystemExit("Unreviewed Go entropy source; review the QDC507 allocation overlay before building")
    source = data.decode()
    if '"sync"' not in source:
        source = source.replace('import entropy "crypto/internal/entropy/v1.0.0"',
                                'import entropy "crypto/internal/entropy/v1.0.0"\nimport "sync"')
    source = source.replace(
        "var memory entropy.ScratchBuffer",
        "// QDC507 overlay: lazy allocation avoids a 32 MiB ELF BSS reservation.\n"
        "var memory *entropy.ScratchBuffer\nvar memoryOnce sync.Once")
    source = source.replace("func getEntropy() *[SeedSize]byte {",
                            "func getEntropy() *[SeedSize]byte {\n"
                            "\tmemoryOnce.Do(func() { memory = new(entropy.ScratchBuffer) })")
    source = source.replace("entropy.Seed(&memory)", "entropy.Seed(memory)")
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    replacement = destination / "entropy_fips140.go"
    replacement.write_text(source)
    (destination / "overlay.json").write_text(json.dumps({"Replace": {str(original): str(replacement)}}))
    (destination / "source.sha256").write_text(digest + "\n")


if __name__ == "__main__":
    prepare(sys.argv[1])
