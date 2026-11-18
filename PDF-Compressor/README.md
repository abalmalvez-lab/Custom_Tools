# PDF-Compressor

A single-file PowerShell tool that shrinks PDFs locally. No uploads, no
accounts, no watermark. It re-encodes the embedded images through an
escalating ladder of quality tiers until your size target is met, then writes
the result next to the original as `<name>-compressed.pdf`.

## Why I built this

I got tired of bouncing PDFs through "free online compressors" to fit email
attachments and portal upload limits. They cap file sizes, add watermarks,
put the document on someone else's server, and the output quality is a black
box. This script does the same job offline, is honest about what it did (it
reports the exact DPI/quality tier it used), and never touches the original.

## How it works

1. **Structural pass**: garbage-collects dead objects and deflates streams.
   Often enough on its own.
2. **Image ladder**: if still over target, it retries with progressively
   more aggressive resample/re-encode tiers (170 → 72 dpi, JPEG q70 → q30),
   stopping at the first tier that hits the target. Last resort converts
   images to grayscale.
3. **Report**: prints input size, output size, reduction %, and the tier
   that produced the result. If nothing can reach the target it keeps the
   best attempt and exits with code 2.

## Requirements

- Windows + PowerShell 5.1 or later
- Python 3.8+ (auto-installed via `winget` if missing)
- PyMuPDF ≥ 1.26 (auto-installed/upgraded via `pip` if missing, see
  `requirements.txt`)

## Usage

```powershell
# Default: at least 70% smaller, writes <name>-compressed.pdf
.\PDF-Compressor.ps1 "C:\Docs\big.pdf"

# Hard ceiling — e.g. 5 MB email/portal limit
.\PDF-Compressor.ps1 "report.pdf" -TargetMB 5 -Force

# Gentler pass when quality matters more than size
.\PDF-Compressor.ps1 "contract.pdf" -MinReduction 50

# Custom output location
.\PDF-Compressor.ps1 "report.pdf" -OutputPath "D:\Shared\report-small.pdf"

# Batch a whole folder to <= 1 MB each
Get-ChildItem "C:\Invoices\*.pdf" | ForEach-Object {
    .\PDF-Compressor.ps1 $_.FullName -TargetMB 1 -Force
}
```

| Parameter | Default | Purpose |
|-----------------|--------------------------|-------------------------------------------|
| `-Path`         | *(required)* | Input PDF |
| `-OutputPath`   | `<name>-compressed.pdf`  | Where to write the result |
| `-TargetMB`     | `0` (off) | Absolute size ceiling in MB |
| `-MinReduction` | `70`                     | Minimum % smaller vs. input |
| `-Force`        | off | Overwrite an existing output file |

If both `-TargetMB` and `-MinReduction` are given, the stricter target wins.
The source file is never modified.

## Exit codes

| Code | Meaning |
|------|------------------------------------------------------|
| 0 | Success, output met the target |
| 1 | Error, bad input, missing dependency, engine failure|
| 2 | Best effort, output kept but target was unreachable |

## Created By

Anthony Almalvez
