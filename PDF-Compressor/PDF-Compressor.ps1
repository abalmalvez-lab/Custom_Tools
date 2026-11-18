<#
Created By: Anthony Almalvez

.SYNOPSIS
Compresses a PDF by downsampling and re-encoding embedded images.

.DESCRIPTION
Reduces PDF file size using PyMuPDF: structural cleanup (garbage collection,
stream deflation, object streams) plus an escalating ladder of image
resample/re-encode tiers until the output meets the requested size target.

Targets are specified either as an absolute size ceiling (-TargetMB) or as a
minimum reduction percentage (-MinReduction, default 70%). If both are given,
the stricter target wins. The source file is never modified; the compressed
PDF is written to -OutputPath (default: <name>-compressed.pdf next to input).

Dependencies (auto-provisioned when missing):
  * Python 3.8+      - searched on PATH and in standard install locations;
                       if absent, installed at user scope via winget.
  * PyMuPDF >= 1.26  - probed for the rewrite_images API the pipeline needs;
                       installed/upgraded at user scope via pip.
  See requirements.txt for the dependency floor.

.PARAMETER Path
Path to the input PDF file.

.PARAMETER OutputPath
Output path for the compressed PDF. Defaults to <name>-compressed.pdf in the
same directory as the input.

.PARAMETER TargetMB
Absolute target size ceiling in megabytes (e.g. -TargetMB 5).

.PARAMETER MinReduction
Minimum reduction in percent relative to the input size. Default 70.
The effective target is the smaller of the -TargetMB and -MinReduction limits.

.PARAMETER Force
Overwrite -OutputPath if it already exists.

.EXAMPLE
.\PDF-Compressor.ps1 "C:\Docs\big.pdf"

Default scenario: writes C:\Docs\big-compressed.pdf targeting at least 70%
smaller than the input. Fails if the output file already exists.

.EXAMPLE
.\PDF-Compressor.ps1 -Path "C:\Temp\Test.PDF\PROJ2_appendix.pdf" -TargetMB 5 -Force

Fit under a hard ceiling: compress until the output is <= 5 MB, overwriting a
previous -compressed.pdf if present. Typical use: email/upload size limits.

.EXAMPLE
.\PDF-Compressor.ps1 ".\scans\contract.pdf" -MinReduction 50

Gentler compression: only requires >= 50% reduction. Stops at the least
aggressive tier that hits the target, preserving more image quality.

.EXAMPLE
.\PDF-Compressor.ps1 "C:\Docs\report.pdf" -TargetMB 10 -MinReduction 60

Both targets given: the stricter one wins. A 30 MB input must come out <= 10 MB
AND <= 12 MB (40% of input), so 10 MB is the effective target.

.EXAMPLE
.\PDF-Compressor.ps1 "C:\Docs\report.pdf" -OutputPath "D:\Shared\report-small.pdf"

Write the result somewhere other than the default <name>-compressed.pdf.

.EXAMPLE
.\PDF-Compressor.ps1 "C:\Docs\report.pdf" -TargetMB 2

Aggressive squeeze on a stubborn file. If the output still exceeds 2 MB after
the most aggressive tier (72 dpi, q30, grayscale), the script keeps the best
result, prints a warning, and exits with code 2.

.EXAMPLE
Get-ChildItem "C:\Invoices\*.pdf" | ForEach-Object {
    .\PDF-Compressor.ps1 $_.FullName -TargetMB 1 -Force
}

Batch scenario: compress every PDF in a folder to <= 1 MB each.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [double]$TargetMB = 0,

    [Parameter(Mandatory = $false)]
    [double]$MinReduction = 70,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Resolve and validate input -------------------------------------------
$src = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
if ([IO.Path]::GetExtension($src) -ne '.pdf') {
    Write-Error "Input is not a PDF file: $src"
    exit 1
}
$srcItem = Get-Item -LiteralPath $src
$srcBytes = $srcItem.Length
$srcMB = [math]::Round($srcBytes / 1MB, 2)

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $srcItem.DirectoryName ($srcItem.BaseName + '-compressed.pdf')
}
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    Write-Error "Output already exists: $OutputPath (use -Force to overwrite)"
    exit 1
}
if ($OutputPath -eq $src) {
    Write-Error "OutputPath must differ from the input file."
    exit 1
}

# --- Compute effective target ---------------------------------------------
$targets = @()
if ($TargetMB -gt 0)   { $targets += [long]($TargetMB * 1MB) }
if ($MinReduction -gt 0) { $targets += [long]($srcBytes * (100 - $MinReduction) / 100.0) }
if ($targets.Count -eq 0) { $targets += [long]($srcBytes * 0.3) }
$targetBytes = ($targets | Measure-Object -Minimum).Minimum
$targetMB = [math]::Round($targetBytes / 1MB, 2)

Write-Host "Input : $src  ($srcMB MB)"
Write-Host "Target: <= $targetMB MB"

# --- Locate Python 3.x -----------------------------------------------------
function Find-Python {
    $candidates = @(
        @{ exe = 'py';      args = @('-3') },
        @{ exe = 'python';  args = @() },
        @{ exe = 'python3'; args = @() }
    )
    # Standard install locations, in case PATH was not refreshed yet
    $candidates += Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                                "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        ForEach-Object { @{ exe = $_.FullName; args = @() } }

    foreach ($c in $candidates) {
        if (-not (Get-Command $c.exe -ErrorAction SilentlyContinue)) { continue }
        try {
            & $c.exe @($c.args) -c "import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)" 2>$null
            if ($LASTEXITCODE -eq 0) { return $c }
        } catch { }
    }
    return $null
}

$py = Find-Python
if (-not $py) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "Python not found - installing Python 3.13 (user scope) via winget..."
        & winget install --id Python.Python.3.13 -e --silent `
            --accept-source-agreements --accept-package-agreements --scope user
        # Refresh PATH so the new interpreter is visible in this session
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User')
        $py = Find-Python
    }
}
if (-not $py) {
    Write-Error "Python 3.8+ not found. Install it (e.g. 'winget install Python.Python.3.13') and retry."
    exit 1
}
$python = $py.exe
$pythonArgs = $py.args
$pyVersion = (& $python @pythonArgs -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null)
Write-Host "Python: $python $($pythonArgs -join ' ') ($pyVersion)"

# --- Ensure PyMuPDF --------------------------------------------------------
# Probe: exit 0 = ok, 2 = not installed, 3 = installed but lacks rewrite_images.
$probePy = @'
import sys
try:
    import pymupdf as m
except ImportError:
    try:
        import fitz as m          # pre-1.26 module name
    except ImportError:
        sys.exit(2)
ver = getattr(m, '__version__', getattr(m, 'VersionBind', 'unknown'))
print(ver)
sys.exit(0 if hasattr(m.Document, 'rewrite_images') else 3)
'@

$probeVer = & $python @pythonArgs -c $probePy 2>$null
$probeCode = $LASTEXITCODE
if ($probeCode -ne 0) {
    if ($probeCode -eq 3) {
        Write-Host "PyMuPDF $probeVer is too old (no rewrite_images support) - upgrading..."
    } else {
        Write-Host "PyMuPDF not found - installing (user scope)..."
    }
    & $python @pythonArgs -m pip --version *>$null
    if ($LASTEXITCODE -ne 0) {
        & $python @pythonArgs -m ensurepip --upgrade *>$null
    }
    & $python @pythonArgs -m pip install --user --upgrade --quiet "pymupdf>=1.26"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install PyMuPDF. Run: $python -m pip install --user pymupdf"
        exit 1
    }
    $probeVer = & $python @pythonArgs -c $probePy 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "PyMuPDF installed but rewrite_images is unavailable (version $probeVer). Update Python/PyMuPDF and retry."
        exit 1
    }
}

# --- Embedded compressor ---------------------------------------------------
$pyScript = @'
import json, os, sys

try:
    import pymupdf
except ImportError:
    import fitz as pymupdf        # pre-1.26 module name

src, dst, target = sys.argv[1], sys.argv[2], int(sys.argv[3])
src_size = os.path.getsize(src)

# (dpi_threshold, dpi_target, jpeg_quality, gray) - least to most aggressive.
# PyMuPDF requires dpi_target < dpi_threshold.
TIERS = [
    (170, 150, 70, False),
    (120, 110, 55, False),
    (110,  96, 50, False),
    (100,  90, 42, False),
    ( 96,  80, 38, False),
    ( 90,  72, 32, False),
    ( 90,  72, 30, True),   # last resort: grayscale
]
SAVE = dict(garbage=4, deflate=True, deflate_images=True,
            deflate_fonts=True, use_objstms=1)

def attempt(dst_path, tier=None):
    doc = pymupdf.open(src)
    if doc.needs_pass:
        doc.close()
        raise RuntimeError("PDF is password-protected")
    if tier is not None:
        thr, dpi, q, gray = tier
        doc.rewrite_images(dpi_threshold=thr, dpi_target=dpi,
                           quality=q, set_to_gray=gray)
    doc.save(dst_path, **SAVE)
    doc.close()
    return os.path.getsize(dst_path)

# Jump-in point on the ladder based on how much must be removed.
ratio = target / src_size
start = 0 if ratio >= 0.60 else (2 if ratio >= 0.25 else 3)

best_size, best_label, tries = None, None, []
size = attempt(dst)
tries.append({"tier": "structural", "bytes": size})
best_size, best_label = size, "structural"

if size > target:
    for i in range(start, len(TIERS)):
        thr, dpi, q, gray = TIERS[i]
        size = attempt(dst, TIERS[i])
        label = f"dpi={dpi}/q={q}" + ("/gray" if gray else "")
        tries.append({"tier": label, "bytes": size})
        if size < best_size:
            best_size, best_label = size, label
        if size <= target:
            break

print(json.dumps({
    "ok": best_size <= target,
    "input_bytes": src_size,
    "output_bytes": best_size,
    "reduction_pct": round(100 * (1 - best_size / src_size), 1),
    "tier": best_label,
    "attempts": tries,
}))
'@

$tmpPy = Join-Path $env:TEMP ("lf_pdf_compress_" + [guid]::NewGuid().ToString('N') + ".py")
try {
    Set-Content -LiteralPath $tmpPy -Value $pyScript -Encoding UTF8
    $json = & $python @pythonArgs $tmpPy "$src" "$OutputPath" "$targetBytes"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Compression failed: $json"
        exit 1
    }
    $result = $json | ConvertFrom-Json
} finally {
    Remove-Item -LiteralPath $tmpPy -ErrorAction SilentlyContinue
}

$outMB = [math]::Round($result.output_bytes / 1MB, 2)
Write-Host ("Output: {0}  ({1} MB, -{2}%, tier: {3})" -f $OutputPath, $outMB, $result.reduction_pct, $result.tier)
if ($result.ok) {
    exit 0
} else {
    Write-Warning "Could not reach target (best: $outMB MB at tier $($result.tier))."
    exit 2
}
