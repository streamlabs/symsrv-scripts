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
$largeFolder = Join-Path $scratchRoot "symbols_large$PID"
$outputFolder = Join-Path $scratchRoot "symstore_temp$PID"
$dbgToolsPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x86"
$symStorePath = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\symstore.exe"

$storeBucket = "slobs-symbol.streamlabs.com"
$storeRegion = "us-east-2"
$storePrefix = "symbols"

$debugEnv = "$env:SYMSRV_DEBUG".Trim()
$isDebug = $debugOutput.IsPresent -or ($debugEnv -and @('0','false','no','off') -notcontains $debugEnv.ToLower())

# symstore /compress spans its cabinet output once a pdb gets big enough, and hands every cabinet
# in the set the same filename - so only the last one survives on disk, and no client can expand
# it. Pdb's over this go through makecab below instead, which is told to stay in one cabinet.
$largePdbThreshold = 1GB

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

# A cabinet that is one part of a spanned set downloads fine and then fails to expand on every
# client, so the only place it can be caught is here. Returns why it is unusable, or $null.
function Test-SingleCabinet
{
       param([string] $path)

       $header = New-Object byte[] 36
       $stream = [System.IO.File]::OpenRead($path)

       try
       {
              $read = $stream.Read($header, 0, $header.Length)
       }
       finally
       {
              $stream.Dispose()
       }

       if ($read -ne $header.Length)
       {
              return "shorter than a cabinet header"
       }

       if ([System.Text.Encoding]::ASCII.GetString($header, 0, 4) -ne 'MSCF')
       {
              return "not a cabinet"
       }

       $declared = [System.BitConverter]::ToUInt32($header, 8)
       $flags = [System.BitConverter]::ToUInt16($header, 30)
       $index = [System.BitConverter]::ToUInt16($header, 34)
       $actual = (Get-Item -LiteralPath $path).Length

       if ($declared -ne $actual)
       {
              return "header declares $declared bytes, file is $actual"
       }

       # cfhdrPREV_CABINET | cfhdrNEXT_CABINET
       if (($flags -band 0x3) -ne 0 -or $index -ne 0)
       {
              return ("cabinet {0} of a spanned set (flags 0x{1:X4})" -f $index, $flags)
       }

       return $null
}

# Replaces a pdb symstore stored uncompressed with the .pd_ a client will ask for. MaxDiskSize=0
# is the part that matters - it is what keeps the output in a single cabinet. LZX 21 matches what
# symstore /compress produces for everything else. Returns why it failed, or $null.
function Compress-StorePdb
{
       param([string] $storedPdb)

       $cab = $storedPdb.Substring(0, $storedPdb.Length - 1) + '_'
       $scratch = Join-Path $scratchRoot "makecab_temp$PID"

       Reset-Folder $scratch

       try
       {
              $log = & makecab.exe /D MaxDiskSize=0 /D CompressionType=LZX /D CompressionMemory=21 `
                     /D "InfFileName=$(Join-Path $scratch 'setup.inf')" `
                     /D "RptFileName=$(Join-Path $scratch 'setup.rpt')" `
                     $storedPdb $cab 2>&1
              $code = $LASTEXITCODE
       }
       finally
       {
              Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
       }

       # makecab reports a percentage per block and no verbosity flag turns it off, which is tens
       # of thousands of lines on a pdb big enough to get here
       $log = @($log | Where-Object { $_ -notmatch '^\s*\d+\.\d+%' })

       Write-SymsrvDebug ($log -join [Environment]::NewLine)

       if ($code -ne 0 -or -Not (Test-Path -LiteralPath $cab))
       {
              Write-Host ($log -join [Environment]::NewLine)
              return "makecab returned $code"
       }

       Remove-Item -LiteralPath $storedPdb -Force

       return $null
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

# Hold the oversized pdb's back from the /compress pass; they get compressed further down
Reset-Folder $outputFolder
Reset-Folder $largeFolder

foreach ($pdb in @(Get-ChildItem -LiteralPath $symbolsFolder -Filter *.pdb -File))
{
       if ($pdb.Length -gt $largePdbThreshold)
       {
              Write-Host ("Too large for symstore compression, handling separately: $($pdb.Name) ({0:N0} bytes)" -f $pdb.Length)
              Move-Item -LiteralPath $pdb.FullName -Destination (Join-Path $largeFolder $pdb.Name) -Force
       }
}

# Run symstore on all of the .pdb's
if (@(Get-ChildItem -LiteralPath $symbolsFolder -Filter *.pdb -File).Count -gt 0)
{
       & $symStorePath add /compress /r /f $symbolsFolder /s $outputFolder /t SLOBS

       if ($LASTEXITCODE -ne 0)
       {
              Write-Warning "symstore returned $LASTEXITCODE"
       }
}

# The oversized ones go in uncompressed so symstore works out the key and builds the folder, then
# each is compressed in place. A pdb left behind here would never be asked for by that name once
# a .pd_ is expected, so a makecab failure has to stop the run rather than upload half a store.
$largePdbs = @(Get-ChildItem -LiteralPath $largeFolder -Filter *.pdb -File)

if ($largePdbs.Count -gt 0)
{
       & $symStorePath add /r /f $largeFolder /s $outputFolder /t SLOBS

       if ($LASTEXITCODE -ne 0)
       {
              Write-Warning "symstore returned $LASTEXITCODE"
       }

       foreach ($large in $largePdbs)
       {
              # Nothing downstream looks at these by name, so an empty result here would drop the
              # symbol from the upload without anything else noticing
              $stored = @(Get-ChildItem -LiteralPath $outputFolder -Filter $large.Name -Recurse -File)

              if ($stored.Count -eq 0)
              {
                     Write-Error "symstore did not store $($large.Name)"
                     exit 1
              }

              foreach ($file in $stored)
              {
                     Write-Host "Compressing $($file.Name) with makecab"
                     $failure = Compress-StorePdb -storedPdb $file.FullName

                     if ($failure)
                     {
                            Write-Error "Could not compress $($file.FullName): $failure"
                            exit 1
                     }
              }
       }
}

$cabs = @(Get-ChildItem -LiteralPath $outputFolder -Filter *.pd_ -Recurse -File -ErrorAction SilentlyContinue)

if ($cabs.Count -eq 0)
{
       Write-Error "symstore produced no compressed symbols from $($remaining.Count) pdb's"
       exit 1
}

$badCabs = @()

foreach ($cab in $cabs)
{
       $failure = Test-SingleCabinet -path $cab.FullName

       if ($failure)
       {
              $badCabs += "$($cab.FullName): $failure"
       }
}

if ($badCabs.Count -gt 0)
{
       Write-Error ("Unusable compressed symbols, refusing to upload:" + [Environment]::NewLine + ($badCabs -join [Environment]::NewLine))
       exit 1
}

Write-Host "$($cabs.Count) compressed symbol file(s) verified as single cabinets"

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
       Remove-Item -LiteralPath $largeFolder -Recurse -Force -ErrorAction SilentlyContinue
}
catch
{
       Write-Error "s3upload.ps1 failed"

       Remove-Item -LiteralPath $outputFolder -Recurse -Force -ErrorAction SilentlyContinue
       Remove-Item -LiteralPath $symbolsFolder -Recurse -Force -ErrorAction SilentlyContinue
       Remove-Item -LiteralPath $largeFolder -Recurse -Force -ErrorAction SilentlyContinue

       # Run the failure upward to the calling script if there is one
       exit 1
}
