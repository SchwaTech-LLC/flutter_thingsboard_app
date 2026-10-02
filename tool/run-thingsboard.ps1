[CmdletBinding()]
param(
    [string]$ConfigPath = "config\thingsboard.local.json",
    [ValidateSet("debug", "profile", "release")]
    [string]$Mode = "debug",
    [string]$Device,
    [switch]$BuildApk
)

$ErrorActionPreference = "Stop"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $repositoryRoot

$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if ($null -eq $flutterCommand) {
    throw "Flutter is not available on PATH. Install Flutter 3.29.0 or add its bin directory to PATH, then reopen PowerShell."
}

& (Join-Path $repositoryRoot "tool\prepare-thingsboard.ps1") -ConfigPath $ConfigPath
if (-not $?) {
    exit 1
}

& $flutterCommand.Source pub get
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$defineArgument = "--dart-define-from-file=$ConfigPath"
if ($BuildApk) {
    $flutterArguments = @("build", "apk", "--$Mode", "--no-tree-shake-icons", $defineArgument)
} else {
    $flutterArguments = @("run", $defineArgument)
    if ($Mode -ne "debug") {
        $flutterArguments += "--$Mode"
    }
}

if (-not [string]::IsNullOrWhiteSpace($Device)) {
    $flutterArguments += @("-d", $Device)
}

& $flutterCommand.Source @flutterArguments
exit $LASTEXITCODE
