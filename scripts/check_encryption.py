#!/usr/bin/env python3
"""Verify platen's AES-256 encryption interoperates with qpdf.

Generates an encrypted PDF via the platen CLI-equivalent test binary is
overkill; instead this drives the same path the integration test uses and
checks qpdf's independent decryption. Run after `zig build`.
"""
import subprocess, sys, tempfile, os

def main():
    pdf = "test/output/encrypted.pdf"
    if not os.path.exists(pdf):
        print(f"skip: {pdf} not found (run the enc_check example or integration test first)")
        return 0

    # Wrong password must fail
    r = subprocess.run(["qpdf", "--check", pdf], capture_output=True, text=True)
    assert r.returncode != 0 and "invalid password" in (r.stdout + r.stderr).lower(), \
        "expected wrong-password rejection"

    # Correct password must validate, report R=6, and decrypt cleanly
    r = subprocess.run(["qpdf", "--password=hunter2", "--check", pdf],
                       capture_output=True, text=True)
    assert r.returncode == 0, f"qpdf check failed:\n{r.stdout}{r.stderr}"
    assert "R = 6" in r.stdout, "expected security handler R=6"

    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp:
        out = tmp.name
    try:
        r = subprocess.run(["qpdf", "--password=hunter2", "--decrypt", pdf, out],
                           capture_output=True, text=True)
        assert r.returncode == 0, f"decrypt failed:\n{r.stderr}"
        r = subprocess.run(["qpdf", "--check", out], capture_output=True, text=True)
        assert "not encrypted" in r.stdout.lower() and "No syntax" in r.stdout
        print("OK: qpdf validates R6 AES-256, enforces password, decrypts cleanly")
    finally:
        os.unlink(out)
    return 0

if __name__ == "__main__":
    sys.exit(main())
