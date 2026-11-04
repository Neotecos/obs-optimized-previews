param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$version = (Get-Content buildspec.json | ConvertFrom-Json).version
$build = "build_windows-$Architecture"
cmake --preset "windows-$Architecture" -DOP_BUILD_TESTS=OFF
if ($LASTEXITCODE) { throw 'Configure failed' }
cmake --build --preset "windows-$Architecture" --parallel
if ($LASTEXITCODE) { throw 'Build failed' }
$stage = Join-Path (Get-Location) "$build/package"
cmake --install $build --config Release --prefix $stage
if ($LASTEXITCODE) { throw 'Staging failed' }
# PDBs are debugging artifacts, not installer payload.
Get-ChildItem $stage -Filter *.pdb -Recurse | Remove-Item
$out = Join-Path (Get-Location) 'release'
New-Item -Force -ItemType Directory $out | Out-Null
$isccCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
$iscc = if ($isccCommand) { $isccCommand.Source } else { "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
& $iscc "/DPluginVersion=$version" "/DPackageArch=$Architecture" "/DStageDir=$stage" "/DOutputDir=$out" packaging/windows.iss
if ($LASTEXITCODE) { throw 'Installer generation failed' }
Compress-Archive -Force -Path "$stage/obs-optimized-previews" -DestinationPath "$out/obs-optimized-previews-$version-windows-$Architecture.zip"
Get-ChildItem $out -File | Where-Object { $_.Extension -in '.exe', '.zip' } | ForEach-Object {
  $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
  "$hash  $($_.Name)" | Set-Content -Encoding ascii "$($_.FullName).sha256"
}
