param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$version = (Get-Content buildspec.json | ConvertFrom-Json).version
$build = "build_windows-$Architecture"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsVersion = & $vswhere -latest -products '*' -property installationVersion
if (-not $vsVersion) { throw 'Visual Studio with the C++ desktop workload is required' }
$generator = if ([version]$vsVersion -ge [version]'18.0') { 'Visual Studio 18 2026' } else { 'Visual Studio 17 2022' }
cmake --preset "windows-$Architecture" -G $generator -DOP_BUILD_TESTS=OFF
if ($LASTEXITCODE) { throw 'Configure failed' }
cmake --build --preset "windows-$Architecture" --parallel
if ($LASTEXITCODE) { throw 'Build failed' }
$stage = Join-Path (Get-Location) "$build/package"
cmake --install $build --config Release --prefix $stage
if ($LASTEXITCODE) { throw 'Staging failed' }
# Fail before packaging if stale binaries or resources survived a previous build.
$manifest = Get-Content "$stage/obs-optimized-previews/data/manifest.json" | ConvertFrom-Json
$dll = Join-Path $stage 'obs-optimized-previews/bin/64bit/obs-optimized-previews.dll'
$dllVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($dll)
if ($manifest.version -ne $version -or $dllVersion.ProductVersion -ne $version) {
  throw "Staged DLL/manifest version does not match buildspec.json ($version)"
}
# PDBs are debugging artifacts, not installer payload.
Get-ChildItem $stage -Filter *.pdb -Recurse | Remove-Item
$out = Join-Path (Get-Location) 'release'
New-Item -Force -ItemType Directory $out | Out-Null
$isccCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
$iscc = if ($isccCommand) { $isccCommand.Source } else { "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
& $iscc "/DPluginVersion=$version" "/DPackageArch=$Architecture" "/DStageDir=$stage" "/DOutputDir=$out" packaging/windows.iss
if ($LASTEXITCODE) { throw 'Installer generation failed' }
$installer = Join-Path $out "obs-optimized-previews_${version}_windows-${Architecture}.exe"
$installerVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($installer)
$expectedVersion = [version]$version
Write-Output "Installer metadata: ProductVersion=$($installerVersion.ProductVersion); FileVersion=$($installerVersion.FileVersion)"
if ($installerVersion.ProductMajorPart -ne $expectedVersion.Major -or
    $installerVersion.ProductMinorPart -ne $expectedVersion.Minor -or
    $installerVersion.ProductBuildPart -ne $expectedVersion.Build) {
  throw "Installer numeric product version does not match $version"
}
# Exercise the actual Installed Apps entry on disposable CI runners.
if ($env:CI -eq 'true') {
  $testRoot = Join-Path ([IO.Path]::GetTempPath()) "op-install-$Architecture"
  $process = Start-Process $installer -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$testRoot`"") -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw 'Installer smoke test failed' }
  $entry = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{B3B9F4C4-5D0E-4C1D-9A55-6A0C8B3A2F71}_is1'
  if ($entry.DisplayVersion -ne $version -or $entry.DisplayName -ne "Optimized Previews for OBS Studio v$version") {
    throw 'Installed Apps version/name does not match the release'
  }
  Write-Output "Verified Installed Apps: $($entry.DisplayName), DisplayVersion=$($entry.DisplayVersion)"
  Start-Process "$testRoot/obs-optimized-previews/uninstall/unins000.exe" -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait
}
$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLower()
"$hash  $([IO.Path]::GetFileName($installer))" | Set-Content -Encoding ascii "$installer.sha256"
