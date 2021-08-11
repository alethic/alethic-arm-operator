param(
    [string]$Configuration = 'Release',
    [string]$Platform = 'Any CPU',
    [string]$Version = '0.0.0',
    [string]$FullVersion = '0.0.0.0',
    [string]$FileVersion = '0.0.0.0',

    [ValidateSet('all', 'dotnet', 'docker', 'helm')]
    [string]$Stage = 'all'
)

$ErrorActionPreference = 'Stop'

# default build output
$env:ROOTDIR = $PSScriptRoot
$env:BUILDDIR = Join-Path $env:ROOTDIR 'build'
$env:VERSION = $Version
$env:FILEVERSION = $FileVersion
$env:FULLVERSION = $FullVersion

# normalize to relative
$env:ROOTDIR = [System.IO.Path]::GetFullPath($env:ROOTDIR)
$env:BUILDDIR = [System.IO.Path]::GetFullPath($env:BUILDDIR)

# debug
echo "ROOTDIR: $env:ROOTDIR"
echo "BUILDDIR: $env:BUILDDIR"
echo "VERSION: $env:VERSION"
echo "FULLVERSION: $env:FULLVERSION"
echo "FILEVERSION: $env:FILEVERSION"

if ($Stage -eq 'all' -or $Stage -eq 'dotnet') {
    # build dotnet
    dotnet restore 'Alethic.Kubernetes.Azure.ResourceManager.sln'; if ($LASTEXITCODE -ne 0) { throw $LASTEXITCODE };
    msbuild 'Alethic.Kubernetes.Azure.ResourceManager.artifacts.proj' /p:Configuration=$Configuration /p:Platform=$Platform /p:Version=$Version /p:AssemblyVersion=$FileVersion /p:InformationalVersion=$FullVersion /p:FileVersion=$FileVersion; if ($LASTEXITCODE -ne 0) { throw $LASTEXITCODE };
}

# compress a file using gzip
Function GZip-File([ValidateScript({Test-Path $_})][string]$File) {
 
    $srcFile = Get-Item -Path $File
    $dstFileName = "$($srcFile.FullName).gz"
 
    try
    {
        $srcFileStream = New-Object System.IO.FileStream($srcFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $dstFileStream = New-Object System.IO.FileStream($dstFileName, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $gzip = New-Object System.IO.Compression.GZipStream($dstFileStream, [System.IO.Compression.CompressionMode]::Compress, [System.IO.Compression.CompressionLevel]::Optimal)
        $srcFileStream.CopyTo($gzip)
    } 
    finally
    {
        $gzip.Dispose()
        $dstFileStream.Dispose()
        $srcFileStream.Dispose()
    }
}

if ($Stage -eq 'all' -or $Stage -eq 'docker') {
    # build docker images
    docker-compose build; if ($LASTEXITCODE -ne 0) { throw $LASTEXITCODE };
    Remove-Item -LiteralPath $(Join-Path $env:BUILDDIR "docker" "tmp") -Recurse -Force
    
    # query for images to save
    $l = docker image list --format '{{.Repository}}:{{.Tag}}' --filter 'label=artifact' | ?{ $_.StartsWith('alethic-arm/') -and $_.EndsWith(":${Version}") }
    $i = 0

    # export all the images
    $l | %{
        Write-Progress -Activity "Exporting" -Status $_ -PercentComplete $(($i / $l.Count) * 100)
        $a=(docker inspect $_ --format='{{ .Config.Labels.artifact }}')
        $p=(Join-Path $env:BUILDDIR "docker" "${a}.tar")
        docker image save $_ -o $p; if ($LASTEXITCODE -ne 0) { throw $LASTEXITCODE }
        GZip-File $p
        Remove-Item -Path $p -Force
        docker image rm $_; if ($LASTEXITCODE -ne 0) { throw $LASTEXITCODE }
        $i++
    }

    Write-Progress -Activity "Exporting" -Completed
}

if ($Stage -eq 'all' -or $Stage -eq 'helm') {
    helm package $(Join-Path $PSScriptRoot "charts" "alethic-arm-operator") --version $Version --app-version $FullVersion -u -d $(Join-Path $env:BUILDDIR "charts")
}