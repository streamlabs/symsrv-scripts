param(
       # The directory path of the github project
       [Parameter(Mandatory = $true)]
       [string] $localSourceDir,

       # The name of user that owns the github repository
       [Parameter(Mandatory = $true)]
       [string] $repo_userId,

       # The name of the repository
       [Parameter(Mandatory = $true)]
       [string] $repo_name,

       # The repository branch
       [Parameter(Mandatory = $true)]
       [string] $repo_branch,

       # Source paths to ignore, format input like this "name,name,name"
       [string[]] $ignoreArray,

       # An array of arrays of strings "one_FolderPath,one_UserName,one_RepoName,one_Branch;two_FolderPath,two_UserName,two_RepoName,two_Branch"
       [string[][]] $subModules,

       # Paths to find .pdb's in, if empty then the path to the project is used
       [string[]] $pdbPaths,

       # Pdb file names to keep out of the store, format input like this "name.pdb,prefix*.pdb"
       [string[]] $excludePdbNames,

       # Index and upload every pdb, even the ones the symbol store already has
       [switch] $forceUpload,

       # Verbose script output and aws --debug. Also enabled by setting SYMSRV_DEBUG=1
       [switch] $debugOutput
)

##
# Variables
##

$subModules_ArrayArray = @(@())

if ($null -ne $subModules)
{
       $subModules = $subModules.split(";")

       foreach ($rawArray in $subModules)
       {
              $rawArray = $rawArray.split(",")
              $subModules_ArrayArray += ,$rawArray
       }
}

if ($null -ne $ignoreArray)
{
       $ignoreArray = $ignoreArray.split(",")
}

if ($null -ne $pdbPaths)
{
       $pdbPaths = $pdbPaths.split(",")
}

if ($null -ne $excludePdbNames)
{
       $excludePdbNames = $excludePdbNames.split(",")
}

# vc140.pdb through vc143.pdb are per-object compiler pdb's. No binary's debug directory ever
# points at one, so a debugger can never request them - the linker pdb carries that code's symbols.
$excludePdbNames = @('vc1??.pdb') + @($excludePdbNames | Where-Object { $_ })

$repo_name = $repo_name -replace "$repo_userId/",""

# Scratch has to live outside the tree. Callers that pass no -pdbPaths search the whole of
# $localSourceDir for pdb's, and this repo is normally checked out inside it, so working folders
# here would sit in the search root - and would survive in a checked out repo if a run died.
$scratchRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } elseif ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }

# Suffixed with the pid so two runs sharing a machine cannot Reset-Folder each other's work
$symbolsFolder = Join-Path $scratchRoot "symbols_temp$PID"
$outputFolder = Join-Path $scratchRoot "symstore_temp$PID"
$dbgToolsPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x86"
$symStorePath = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\symstore.exe"

$storeBucket = "slobs-symbol.streamlabs.com"
$storeRegion = "us-east-2"
$storePrefix = "symbols"

$debugEnv = "$env:SYMSRV_DEBUG".Trim()
$isDebug = $debugOutput.IsPresent -or ($debugEnv -and @('0','false','no','off') -notcontains $debugEnv.ToLower())

##
# Helpers
##

function Write-SymsrvDebug
{
       param([string] $message)

       if ($isDebug)
       {
              Write-Host "DEBUG: $message"
       }
}

function Reset-Folder
{
       param([string] $path)

       if (Test-Path -LiteralPath $path)
       {
              Remove-Item -LiteralPath $path -Recurse -Force
       }
       New-Item -ItemType Directory -Path $path -Force | Out-Null
}

# Flattens every pdb under $sourcePaths into $destination. Names have to be unique in the store
# folder, so a second pdb with the same name wins - which is fine as long as it is not silent.
function Copy-PdbFiles
{
       param(
              [string[]] $sourcePaths,
              [string] $destination,
              [string[]] $excludeNames
       )

       $seen = @{}
       $copied = 0
       $excluded = 0
       $collisions = 0

       foreach ($sourcePath in $sourcePaths)
       {
              if (-Not (Test-Path -LiteralPath $sourcePath))
              {
                     Write-Warning "Pdb search path does not exist, skipping: $sourcePath"
                     continue
              }

              foreach ($pdb in (Get-ChildItem -LiteralPath $sourcePath -Filter *.pdb -Recurse -File -ErrorAction SilentlyContinue))
              {
                     $skip = $false
                     foreach ($pattern in $excludeNames)
                     {
                            if ($pdb.Name -like $pattern)
                            {
                                   $skip = $true
                                   break
                            }
                     }

                     if ($skip)
                     {
                            $excluded++
                            Write-SymsrvDebug "Excluded by name: $($pdb.FullName)"
                            continue
                     }

                     if ($seen.ContainsKey($pdb.Name))
                     {
                            $collisions++
                            Write-Warning "pdb name collision: '$($pdb.FullName)' overwrites '$($seen[$pdb.Name])'"
                     }

                     Copy-Item -LiteralPath $pdb.FullName -Destination (Join-Path $destination $pdb.Name) -Force
                     $seen[$pdb.Name] = $pdb.FullName
                     $copied++
              }
       }

       Write-Host "Collected $copied pdb's ($excluded excluded by name, $collisions name collisions)"

       return $copied
}

# symstore's /x index mode writes out the store key for every pdb without copying or compressing
# anything, so it costs a fraction of a second. /t is rejected in combination with /x.
# Index lines look like: "name.pdb","name.pdb\<GUID><AGE>","name.pdb",typ,,,,
function Get-SymbolStoreEntries
{
       param(
              [string] $symbolsFolder,
              [string] $symStorePath
       )

       $entries = @()
       $indexFile = Join-Path $env:TEMP ("symsrv_index_" + [System.Guid]::NewGuid().ToString("N") + ".txt")

       try
       {
              $indexLog = & $symStorePath add /r /f $symbolsFolder /x $indexFile /g $symbolsFolder 2>&1
              Write-SymsrvDebug ($indexLog -join [Environment]::NewLine)

              if (-Not (Test-Path -LiteralPath $indexFile))
              {
                     Write-Warning "symstore did not produce an index file; every pdb will be uploaded."
                     return $entries
              }

              foreach ($line in (Get-Content -LiteralPath $indexFile))
              {
                     if ($line -notmatch '^"(?<file>[^"]+)","(?<store>[^"]+)"')
                     {
                            continue
                     }

                     $fileName = $matches['file']
                     $storePath = $matches['store']
                     $guid = $storePath.Substring($storePath.LastIndexOf('\') + 1)

                     $entries += [pscustomobject]@{
                            FileName = $fileName
                            Guid = $guid
                            # symstore names the compressed copy by replacing the last character of the extension
                            CompressedName = $fileName.Substring(0, $fileName.Length - 1) + '_'
                     }
              }
       }
       catch
       {
              Write-Warning "Could not index pdb's for a store lookup ($($_.Exception.Message)); every pdb will be uploaded."
              return @()
       }
       finally
       {
              if (Test-Path -LiteralPath $indexFile)
              {
                     Remove-Item -LiteralPath $indexFile -Force -ErrorAction SilentlyContinue
              }
       }

       return $entries
}

# Returns a hashtable of the keys the bucket already holds. Every failure path returns fewer keys
# than are really there, which only ever costs an unnecessary upload - never a missing symbol.
function Get-PresentSymbolKeys
{
       param(
              [string[]] $keys,
              [string] $bucket,
              [string] $region,
              [int] $batchSize = 16,
              [int] $timeoutSeconds = 20
       )

       $present = @{}

       if ($keys.Count -eq 0)
       {
              return $present
       }

       try
       {
              Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
              [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

              if ([System.Net.ServicePointManager]::DefaultConnectionLimit -lt ($batchSize * 2))
              {
                     [System.Net.ServicePointManager]::DefaultConnectionLimit = $batchSize * 2
              }
       }
       catch
       {
              Write-Warning "Symbol store lookup unavailable ($($_.Exception.Message)); every pdb will be uploaded."
              return $present
       }

       # The bucket name contains dots, so virtual host style addressing fails tls verification
       $baseUri = "https://s3.$region.amazonaws.com/$bucket/"
       $client = New-Object System.Net.Http.HttpClient

       try
       {
              $client.Timeout = [TimeSpan]::FromSeconds($timeoutSeconds)

              for ($offset = 0; $offset -lt $keys.Count; $offset += $batchSize)
              {
                     $last = [Math]::Min($offset + $batchSize, $keys.Count) - 1
                     $batch = @($keys[$offset..$last])
                     $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task[System.Net.Http.HttpResponseMessage]]'

                     foreach ($key in $batch)
                     {
                            $escaped = ($key.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
                            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, ($baseUri + $escaped))
                            $tasks.Add($client.SendAsync($request))
                     }

                     try
                     {
                            [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), $timeoutSeconds * 1000) | Out-Null
                     }
                     catch
                     {
                            Write-SymsrvDebug "Store lookup batch reported $($_.Exception.Message)"
                     }

                     for ($i = 0; $i -lt $batch.Count; $i++)
                     {
                            $task = $tasks[$i]

                            if ($task.Status -ne 'RanToCompletion')
                            {
                                   Write-SymsrvDebug "Store lookup did not complete for $($batch[$i])"
                                   continue
                            }

                            if ($task.Result.StatusCode -eq [System.Net.HttpStatusCode]::OK)
                            {
                                   $present[$batch[$i]] = $true
                            }

                            $task.Result.Dispose()
                     }
              }
       }
       catch
       {
              Write-Warning "Symbol store lookup failed ($($_.Exception.Message)); remaining pdb's will be uploaded."
       }
       finally
       {
              $client.Dispose()
       }

       return $present
}

##
# Begin
##

# Debuggers tools from winsdk are required
if (-Not (Test-Path -path $dbgToolsPath))
{
       Write-Output "Installing debuggers tools from winsdk..."
       Invoke-WebRequest https://go.microsoft.com/fwlink/?linkid=2173743 -OutFile winsdksetup.exe;
       start-Process winsdksetup.exe -ArgumentList '/features OptionId.WindowsDesktopDebuggers /q' -Wait;
       Remove-Item -Force winsdksetup.exe;
}

# symstore ships in the x64 folder, so the x86 check above does not cover it
if (-Not (Test-Path -LiteralPath $symStorePath))
{
       Write-Error "symstore.exe not found at $symStorePath. Install the winsdk Windows Desktop Debuggers."
       exit 1
}

# Submodules need the version used at compilation time deduced. Anonymous api.github.com calls are
# limited per IP and shared across runners, so send a token when one is available and treat a
# failure as non fatal - the branch name still resolves, it just is not pinned to a commit.
$githubApiHeaders = @{ 'User-Agent' = 'symsrv-scripts' }
$githubToken = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }

if ($githubToken)
{
       $githubApiHeaders['Authorization'] = "Bearer $githubToken"
}
else
{
       Write-SymsrvDebug "No GH_TOKEN or GITHUB_TOKEN set, querying api.github.com anonymously"
}

for ($i = 0 ; $i -lt $subModules_ArrayArray.Count ; $i++)
{
       $subModule_UserName = $subModules_ArrayArray[$i][1]
       $subModule_RepoName = $subModules_ArrayArray[$i][2]
       $subModule_Branch = $subModules_ArrayArray[$i][3]

       try
       {
              $mainRepoContentJson = (Invoke-WebRequest "https://api.github.com/repos/$subModule_UserName/$subModule_RepoName/commits/$subModule_Branch" -Headers $githubApiHeaders -UseBasicParsing | ConvertFrom-Json)
              $subModules_ArrayArray[$i][3] = $mainRepoContentJson.sha
       }
       catch
       {
              Write-Warning "Could not resolve $subModule_UserName/$subModule_RepoName@$subModule_Branch to a commit ($($_.Exception.Message)). Source links for it will follow the branch instead."
       }
}

# Copy symbols from the source directory
Reset-Folder $symbolsFolder

if ($null -eq $pdbPaths)
{
       $collected = Copy-PdbFiles -sourcePaths @($localSourceDir) -destination $symbolsFolder -excludeNames $excludePdbNames
}
else
{
       $collected = Copy-PdbFiles -sourcePaths $pdbPaths -destination $symbolsFolder -excludeNames $excludePdbNames
}

$collectedAny = ($collected -gt 0)

# Drop everything the store already has before doing any expensive work on it. Indexing writes an
# srcsrv stream into a named pdb stream and leaves the signature alone, so the key computed here
# is the same key symstore will produce after indexing.
$uploadManifest = @()

if ($forceUpload)
{
       Write-Host "-forceUpload set, skipping the symbol store lookup"
}
else
{
       $entries = Get-SymbolStoreEntries -symbolsFolder $symbolsFolder -symStorePath $symStorePath

       if ($entries.Count -gt 0)
       {
              # An all-F guid means symstore could not read a signature out of the pdb, so nothing
              # will ever look the key up. Those are static library compile pdb's.
              $unusable = @($entries | Where-Object { $_.Guid -match '^F+$' })
              $usable = @($entries | Where-Object { $_.Guid -notmatch '^F+$' })

              foreach ($entry in $unusable)
              {
                     Write-SymsrvDebug "Unusable signature, dropping: $($entry.FileName)"
                     Remove-Item -LiteralPath (Join-Path $symbolsFolder $entry.FileName) -Force -ErrorAction SilentlyContinue
              }

              $keys = @($usable | ForEach-Object { "$storePrefix/$($_.FileName)/$($_.Guid)/$($_.CompressedName)" })
              $present = Get-PresentSymbolKeys -keys $keys -bucket $storeBucket -region $storeRegion

              foreach ($entry in $usable)
              {
                     $key = "$storePrefix/$($entry.FileName)/$($entry.Guid)/$($entry.CompressedName)"

                     if ($present.ContainsKey($key))
                     {
                            Write-SymsrvDebug "Already in the store, dropping: $key"
                            Remove-Item -LiteralPath (Join-Path $symbolsFolder $entry.FileName) -Force -ErrorAction SilentlyContinue
                     }
                     else
                     {
                            $uploadManifest += $key
                     }
              }

              Write-Host "Symbol store: $($entries.Count) indexed, $($unusable.Count) without a usable signature, $($present.Count) already stored, $($uploadManifest.Count) to upload"
       }
}

$remaining = @(Get-ChildItem -LiteralPath $symbolsFolder -Filter *.pdb -File -ErrorAction SilentlyContinue)

if ($remaining.Count -eq 0)
{
       if ($collectedAny)
       {
              Write-Host "Nothing to upload, the symbol store already has every pdb from this build."
       }
       else
       {
              Write-Warning "No pdb files were found to upload."
       }

       Remove-Item -LiteralPath $symbolsFolder -Recurse -Force -ErrorAction SilentlyContinue
       exit 0
}

# Edit the pdb's with http addresses
$indexerArgs = @{
       ignoreUnknown = $true
       ignore = $ignoreArray
       sourcesroot = $localSourceDir
       dbgToolsPath = $dbgToolsPath
       symbolsFolder = $symbolsFolder
       userId = $repo_userId
       repository = $repo_name
       branch = $repo_branch
       subModules = $subModules_ArrayArray
}

if ($isDebug)
{
       $indexerArgs['Verbose'] = $true
}

.\github-sourceindexer.ps1 @indexerArgs

# Run symstore on all of the .pdb's
Reset-Folder $outputFolder
& $symStorePath add /compress /r /f $symbolsFolder /s $outputFolder /t SLOBS

if ($LASTEXITCODE -ne 0)
{
       Write-Warning "symstore returned $LASTEXITCODE"
}

if (@(Get-ChildItem -LiteralPath $outputFolder -Filter *.pd_ -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0)
{
       Write-Error "symstore produced no compressed symbols from $($remaining.Count) pdb's"
       exit 1
}

# Record what this build added, since the store's own 000Admin transaction log is not usable
# against a bucket that many builds write to concurrently
$manifestFile = $null

if ($uploadManifest.Count -gt 0)
{
       $manifestFile = Join-Path $scratchRoot "symsrv_manifest_${repo_branch}_$PID.txt"
       Set-Content -LiteralPath $manifestFile -Value $uploadManifest -Encoding ASCII
}

# Upload to aws
try
{
       .\s3upload.ps1 -symStoreFolder $outputFolder -bucket $storeBucket -prefix $storePrefix -region $storeRegion -debugOutput:$isDebug -manifestFile $manifestFile -manifestKey "manifests/$repo_name/$repo_branch.txt"

       # Cleanup
       Remove-Item -LiteralPath $outputFolder -Recurse -Force -ErrorAction SilentlyContinue
       Remove-Item -LiteralPath $symbolsFolder -Recurse -Force -ErrorAction SilentlyContinue
}
catch
{
       Write-Error "s3upload.ps1 failed"

       Remove-Item -LiteralPath $outputFolder -Recurse -Force -ErrorAction SilentlyContinue
       Remove-Item -LiteralPath $symbolsFolder -Recurse -Force -ErrorAction SilentlyContinue

       # Run the failure upward to the calling script if there is one
       exit 1
}
