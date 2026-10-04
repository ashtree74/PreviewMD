param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$Manifest
)

$ErrorActionPreference = "Stop"

function Get-RendererLines([string]$root, [string]$manifestPath) {
    $fullRoot = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
    $expected = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($manifestPath)) {
        if ($line.Length -gt 0) {
            $expected.Add($line)
        }
    }

    $actual = New-Object System.Collections.Generic.List[string]
    foreach ($file in [System.IO.Directory]::EnumerateFiles($fullRoot, "*", [System.IO.SearchOption]::AllDirectories)) {
        if (-not $file.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "renderer file is outside the tree: $file"
        }
        $relative = $file.Substring($fullRoot.Length).TrimStart('\').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $actual.Add("$hash  $relative")
    }

    $expectedArray = $expected.ToArray()
    $actualArray = $actual.ToArray()
    [Array]::Sort($expectedArray, [StringComparer]::Ordinal)
    [Array]::Sort($actualArray, [StringComparer]::Ordinal)
    return @{ Expected = $expectedArray; Actual = $actualArray }
}

$lines = Get-RendererLines $Directory $Manifest
if ($lines.Expected.Length -ne $lines.Actual.Length) {
    Write-Error "renderer checksum mismatch: manifest has $($lines.Expected.Length) files and the directory has $($lines.Actual.Length)"
    exit 1
}

for ($index = 0; $index -lt $lines.Expected.Length; $index++) {
    if (-not [string]::Equals($lines.Expected[$index], $lines.Actual[$index], [StringComparison]::Ordinal)) {
        Write-Error "renderer checksum mismatch: $($lines.Actual[$index]) != $($lines.Expected[$index])"
        exit 1
    }
}
