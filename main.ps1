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

       # Paths to find .exe, .dll and .node files in, if empty then no binaries are uploaded
       [string[]] $binPaths,

       # Binary file names to keep out of the store, format input like this "name.dll,prefix*.dll"
       [string[]] $excludeBinNames,

       # Index and upload every pdb and binary, even the ones the symbol store already has
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

if ($null -ne $binPaths)
{
       $binPaths = $binPaths.split(",")
}

if ($null -ne $excludeBinNames)
{
       $excludeBinNames = $excludeBinNames.split(",")
}

$excludeBinNames = @('*unit_tests*', 'vc_redist*', '*.tmp') + @($excludeBinNames | Where-Object { $_ })

$repo_name = $repo_name -replace "$repo_userId/",""

# Scratch has to live outside the tree. Callers that pass no -pdbPaths search the whole of
# $localSourceDir for pdb's, and this repo is normally checked out inside it, so working folders
# here would sit in the search root - and would survive in a checked out repo if a run died.
$scratchRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } elseif ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }

# Suffixed with the pid so two runs sharing a machine cannot Reset-Folder each other's work
$symbolsFolder = Join-Path $scratchRoot "symbols_temp$PID"
$binFolder = Join-Path $scratchRoot "symbols_bin$PID"
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
# it. Files over this go through makecab below instead, which is told to stay in one cabinet.
$largeFileThreshold = 1GB

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

# Flattens every file matching $filters under $sourcePaths into $destination. Without
# -keepCollisions a second file with the same name wins, which is fine as long as it is not silent.
# With it, each repeat goes into its own numbered subfolder: same-named binaries are different
# files with different store keys.
function Copy-SymbolFiles
{
       param(
              [string[]] $sourcePaths,
              [string] $destination,
              [string[]] $excludeNames,
              [string[]] $filters,
              [string] $kind,
              [switch] $keepCollisions
       )

       $seen = @{}
       $copied = 0
       $excluded = 0
       $collisions = 0

       foreach ($sourcePath in $sourcePaths)
       {
              if (-Not (Test-Path -LiteralPath $sourcePath))
              {
                     Write-Warning "Search path for $kind does not exist, skipping: $sourcePath"
                     continue
              }

              $found = foreach ($filter in $filters)
              {
                     # -Filter also matches longer extensions that share the first three characters
                     Get-ChildItem -LiteralPath $sourcePath -Filter $filter -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $filter }
              }

              foreach ($file in $found)
              {
                     $skip = $false
                     foreach ($pattern in $excludeNames)
                     {
                            if ($file.Name -like $pattern)
                            {
                                   $skip = $true
                                   break
                            }
                     }

                     if ($skip)
                     {
                            $excluded++
                            Write-SymsrvDebug "Excluded by name: $($file.FullName)"
                            continue
                     }

                     $target = $destination

                     if ($seen.ContainsKey($file.Name))
                     {
                            $collisions++

                            if ($keepCollisions)
                            {
                                   $target = Join-Path $destination $collisions
                                   New-Item -ItemType Directory -Path $target -Force | Out-Null
                                   Write-Warning "$kind name collision: '$($file.FullName)' kept next to '$($seen[$file.Name])'"
                            }
                            else
                            {
                                   Write-Warning "$kind name collision: '$($file.FullName)' overwrites '$($seen[$file.Name])'"
                            }
                     }

                     Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $target $file.Name) -Force
                     $seen[$file.Name] = $file.FullName
                     $copied++
              }
       }

       Write-Host "Collected $copied $kind ($excluded excluded by name, $collisions name collisions)"

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

# Replaces a file symstore stored uncompressed with the compressed name (.pd_, .dl_, ...) a client
# will ask for. MaxDiskSize=0
# is the part that matters - it is what keeps the output in a single cabinet. LZX 21 matches what
# symstore /compress produces for everything else. Returns why it failed, or $null.
function Compress-StoreFile
{
       param([string] $storedFile)

       $cab = $storedFile.Substring(0, $storedFile.Length - 1) + '_'
       $scratch = Join-Path $scratchRoot "makecab_temp$PID"

       Reset-Folder $scratch

       try
       {
              $log = & makecab.exe /D MaxDiskSize=0 /D CompressionType=LZX /D CompressionMemory=21 `
                     /D "InfFileName=$(Join-Path $scratch 'setup.inf')" `
                     /D "RptFileName=$(Join-Path $scratch 'setup.rpt')" `
                     $storedFile $cab 2>&1
              $code = $LASTEXITCODE
       }
       finally
       {
              Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
       }

       # makecab reports a percentage per block and no verbosity flag turns it off, which is tens
       # of thousands of lines on a file big enough to get here
       $log = @($log | Where-Object { $_ -notmatch '^\s*\d+\.\d+%' })

       Write-SymsrvDebug ($log -join [Environment]::NewLine)

       if ($code -ne 0 -or -Not (Test-Path -LiteralPath $cab))
       {
              Write-Host ($log -join [Environment]::NewLine)
              return "makecab returned $code"
       }

       Remove-Item -LiteralPath $storedFile -Force

       return $null
}

# symstore's /x index mode writes out the store key for every file without copying or compressing
# anything, so it costs a fraction of a second. /t is rejected in combination with /x.
# Index lines look like: "name.pdb","name.pdb\<GUID><AGE>","name.pdb",typ,,,,
# or, for a binary: "name.dll","name.dll\<TIMESTAMP><SIZEOFIMAGE>","name.dll",bin,,,,
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
                     Write-Warning "symstore did not produce an index file; every file will be uploaded."
                     return $entries
              }

              foreach ($line in (Get-Content -LiteralPath $indexFile))
              {
                     if ($line -notmatch '^"(?<file>[^"]+)","(?<store>[^"]+)"')
                     {
                            continue
                     }

                     # FileName is relative to the folder, which matters for files in subfolders
                     $fileName = $matches['file']
                     $storePath = $matches['store']
                     $guid = $storePath.Substring($storePath.LastIndexOf('\') + 1)
                     $leaf = Split-Path -Leaf $fileName

                     $entries += [pscustomobject]@{
                            FileName = $fileName
                            StoreName = $leaf
                            Guid = $guid
                            # symstore names the compressed copy by replacing the last character of the extension
                            CompressedName = $leaf.Substring(0, $leaf.Length - 1) + '_'
                     }
              }
       }
       catch
       {
              Write-Warning "Could not index files for a store lookup ($($_.Exception.Message)); every file will be uploaded."
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
              Write-Warning "Symbol store lookup unavailable ($($_.Exception.Message)); every file will be uploaded."
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
              Write-Warning "Symbol store lookup failed ($($_.Exception.Message)); remaining files will be uploaded."
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

# Drops everything the store already has from $folder before doing any expensive work on it, and
# returns the keys of what is left. Indexing writes an srcsrv stream into a named pdb stream and
# leaves the signature alone, so the key computed here is the same key symstore will produce
# after indexing.
function Remove-StoredSymbols
{
       param([string] $folder)

       $manifestKeys = @()

       $entries = Get-SymbolStoreEntries -symbolsFolder $folder -symStorePath $symStorePath

       if ($entries.Count -gt 0)
       {
              # An all-F guid means symstore could not read a signature out of the pdb, so nothing
              # will ever look the key up. Those are static library compile pdb's.
              $unusable = @($entries | Where-Object { $_.Guid -match '^F+$' })
              $usable = @($entries | Where-Object { $_.Guid -notmatch '^F+$' })

              foreach ($entry in $unusable)
              {
                     Write-SymsrvDebug "Unusable signature, dropping: $($entry.FileName)"
                     Remove-Item -LiteralPath (Join-Path $folder $entry.FileName) -Force -ErrorAction SilentlyContinue
              }

              $keys = @($usable | ForEach-Object { "$storePrefix/$($_.StoreName)/$($_.Guid)/$($_.CompressedName)" })
              $present = Get-PresentSymbolKeys -keys $keys -bucket $storeBucket -region $storeRegion

              foreach ($entry in $usable)
              {
                     $key = "$storePrefix/$($entry.StoreName)/$($entry.Guid)/$($entry.CompressedName)"

                     if ($present.ContainsKey($key))
                     {
                            Write-SymsrvDebug "Already in the store, dropping: $key"
                            Remove-Item -LiteralPath (Join-Path $folder $entry.FileName) -Force -ErrorAction SilentlyContinue
                     }
                     else
                     {
                            $manifestKeys += $key
                     }
              }

              Write-Host "Symbol store: $($entries.Count) indexed, $($unusable.Count) without a usable signature, $($present.Count) already stored, $($manifestKeys.Count) to upload"
       }

       return $manifestKeys
}

# Pulls files over the size limit out of $folder so the /compress pass never sees them. The path
# relative to $folder is kept, as same-named binaries live in subfolders.
function Move-LargeFiles
{
       param([string] $folder)

       foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Recurse))
       {
              if ($file.Length -gt $largeFileThreshold)
              {
                     $relative = $file.FullName.Substring($folder.Length).TrimStart('\')
                     $destination = Join-Path $largeFolder $relative
                     New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null

                     Write-Host ("Too large for symstore compression, handling separately: $relative ({0:N0} bytes)" -f $file.Length)
                     Move-Item -LiteralPath $file.FullName -Destination $destination -Force
              }
       }
}

# Copy symbols from the source directory
Reset-Folder $symbolsFolder
Reset-Folder $binFolder

$pdbSearchPaths = if ($null -eq $pdbPaths) { @($localSourceDir) } else { $pdbPaths }
$collectedPdbs = Copy-SymbolFiles -sourcePaths $pdbSearchPaths -destination $symbolsFolder -excludeNames $excludePdbNames -filters @('*.pdb') -kind "pdb's"

$collectedBins = 0

if ($null -ne $binPaths)
{
       $collectedBins = Copy-SymbolFiles -sourcePaths $binPaths -destination $binFolder -excludeNames $excludeBinNames -filters @('*.exe', '*.dll', '*.node') -kind "binaries" -keepCollisions
}

# Pdb's and binaries are looked up separately, so a rerun where the pdb's are already stored still
# uploads binaries that are not
$uploadManifest = @()

if ($forceUpload)
{
       Write-Host "-forceUpload set, skipping the symbol store lookup"
}
else
{
       $uploadManifest += Remove-StoredSymbols -folder $symbolsFolder
       $uploadManifest += Remove-StoredSymbols -folder $binFolder
}

$remaining = @(Get-ChildItem -LiteralPath $symbolsFolder -Filter *.pdb -File -ErrorAction SilentlyContinue)
$remainingBins = @(Get-ChildItem -LiteralPath $binFolder -File -Recurse -ErrorAction SilentlyContinue)

if ($remaining.Count -eq 0 -and $remainingBins.Count -eq 0)
{
       if ($collectedPdbs -gt 0 -or $collectedBins -gt 0)
       {
              Write-Host "Nothing to upload, the symbol store already has every pdb and binary from this build."
       }
       else
       {
              Write-Warning "No pdb or binary files were found to upload."
       }

       Remove-Item -LiteralPath $symbolsFolder -Recurse -Force -ErrorAction SilentlyContinue
       Remove-Item -LiteralPath $binFolder -Recurse -Force -ErrorAction SilentlyContinue
       exit 0
}

Reset-Folder $outputFolder
Reset-Folder $largeFolder

if ($remaining.Count -gt 0)
{
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
}

# Hold the oversized files back from the /compress pass; they get compressed further down
Move-LargeFiles -folder $symbolsFolder
Move-LargeFiles -folder $binFolder

# Run symstore on all of the .pdb's
if (@(Get-ChildItem -LiteralPath $symbolsFolder -Filter *.pdb -File).Count -gt 0)
{
       & $symStorePath add /compress /r /f $symbolsFolder /s $outputFolder /t SLOBS

       if ($LASTEXITCODE -ne 0)
       {
              Write-Warning "symstore returned $LASTEXITCODE"
       }
}

# Binaries are stored as they are - no source indexing, they carry no srcsrv stream
if (@(Get-ChildItem -LiteralPath $binFolder -File -Recurse).Count -gt 0)
{
       & $symStorePath add /compress /r /f $binFolder /s $outputFolder /t SLOBS

       # The manifest already lists these keys, so carrying on would record binaries that were never stored
       if ($LASTEXITCODE -ne 0)
       {
              Write-Error "symstore returned $LASTEXITCODE for the binaries"
              exit 1
       }
}

# The oversized ones go in uncompressed so symstore works out the key and builds the folder, then
# each is compressed in place. A file left behind here would never be asked for by that name once
# a compressed one is expected, so a makecab failure has to stop the run rather than upload half a
# store.
$largeFiles = @(Get-ChildItem -LiteralPath $largeFolder -File -Recurse)

if ($largeFiles.Count -gt 0)
{
       & $symStorePath add /r /f $largeFolder /s $outputFolder /t SLOBS

       if ($LASTEXITCODE -ne 0)
       {
              Write-Warning "symstore returned $LASTEXITCODE"
       }

       # The lookup is by name and compresses every store entry of that name, so once per name
       foreach ($large in @($largeFiles | Sort-Object Name -Unique))
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
                     $failure = Compress-StoreFile -storedFile $file.FullName

                     if ($failure)
                     {
                            Write-Error "Could not compress $($file.FullName): $failure"
                            exit 1
                     }
              }
       }
}

# symstore replaces the last character of the extension with an underscore: .pd_, .ex_, .dl_, .nod_
$cabs = @(Get-ChildItem -LiteralPath $outputFolder -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -like '.*_' })

if ($cabs.Count -eq 0)
{
       Write-Error "symstore produced no compressed symbols from $($remaining.Count + $remainingBins.Count) pdb's and binaries"
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
       Remove-Item -LiteralPath $binFolder -Recurse -Force -ErrorAction SilentlyContinue
       Remove-Item -LiteralPath $largeFolder -Recurse -Force -ErrorAction SilentlyContinue
}
catch
{
       Write-Error "s3upload.ps1 failed"

       Remove-Item -LiteralPath $outputFolder -Recurse -Force -ErrorAction SilentlyContinue
       Remove-Item -LiteralPath $symbolsFolder -Recurse -Force -ErrorAction SilentlyContinue
       Remove-Item -LiteralPath $binFolder -Recurse -Force -ErrorAction SilentlyContinue
       Remove-Item -LiteralPath $largeFolder -Recurse -Force -ErrorAction SilentlyContinue

       # Run the failure upward to the calling script if there is one
       exit 1
}
