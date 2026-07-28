param(
       # The directory path of the GitHub project
       [Parameter(Mandatory = $true)]
       [string] $symStoreFolder,

       # Symbol store bucket
       [string] $bucket = "slobs-symbol.streamlabs.com",

       # Key prefix the symbol store lives under
       [string] $prefix = "symbols",

       # Bucket region
       [string] $region = "us-east-2",

       # Local file listing the keys this build added, uploaded to $manifestKey when set
       [string] $manifestFile,

       # Key to store $manifestFile under
       [string] $manifestKey,

       # Pass --debug to the aws cli. Also enabled by setting SYMSRV_DEBUG=1
       [switch] $debugOutput
)

$debugEnv = "$env:SYMSRV_DEBUG".Trim()
$isDebug = $debugOutput.IsPresent -or ($debugEnv -and @('0','false','no','off') -notcontains $debugEnv.ToLower())

# Local environment variables, even if there are system ones with the same name, these are used for the cmd below
Write-Host "S3Upload: Setting AWS environment variables..."
$Env:AWS_ACCESS_KEY_ID = $Env:AWS_SYMB_ACCESS_KEY_ID
$Env:AWS_SECRET_ACCESS_KEY = $Env:AWS_SYMB_SECRET_ACCESS_KEY
$Env:AWS_DEFAULT_REGION = $region
Write-Host "S3Upload: AWS environment variables set."

# 000Admin is symstore's transaction log for the local store this build just created. Copying it
# up would overwrite the bucket's copy with a one transaction history, so it is left behind and
# the manifest below records what was added instead.
$copyArgs = @(
       's3', 'cp', $symStoreFolder, "s3://$bucket/$prefix",
       '--recursive', '--acl', 'public-read',
       '--exclude', '000Admin/*'
)

if ($isDebug) {
    $copyArgs += '--debug'
}

Write-Host "S3Upload: Starting AWS S3 copy..."
try {
    aws @copyArgs

    if ($LastExitCode -ne 0) {
        throw "AWS S3 copy failed with exit code $LastExitCode."
    }
    Write-Host "S3Upload: AWS S3 copy completed successfully."

    if ($manifestFile -and $manifestKey -and (Test-Path -LiteralPath $manifestFile)) {
        Write-Host "S3Upload: Uploading manifest to $manifestKey..."
        aws s3 cp $manifestFile "s3://$bucket/$manifestKey" --acl public-read

        if ($LastExitCode -ne 0) {
            Write-Warning "S3Upload: Manifest upload failed with exit code $LastExitCode."
        }
    }
}
catch {
    Write-Host "S3Upload: Error: $_"
    throw
}
