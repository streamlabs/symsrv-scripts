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
       [string[]] $pdbPaths
)

##
# Variables
##

$subModules_ArrayArray = @(@())

if ($subModules -ne $null)
{
       $subModules = $subModules.split(";")

       foreach ($rawArray in $subModules)
       {
              $rawArray = $rawArray.split(",")
              $subModules_ArrayArray += ,$rawArray
       }
}

if ($ignoreArray -ne $null)
{
       $ignoreArray = $ignoreArray.split(",")
}

if ($pdbPaths -ne $null)
{
       $pdbPaths = $pdbPaths.split(",")
}

$repo_name = $repo_name -replace "$repo_userId/",""
$symbolsFolder = "symbols_tempJ1M39VNNDF"
$outputFolder = "symstore_temp6JB24HH2Z"
$dbgToolsPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x86"

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

# Submodules need the version used at compilation time deduced
for ($i = 0 ; $i -lt $subModules_ArrayArray.Count ; $i++)
{
       $subModule_UserName = $subModules_ArrayArray[$i][1] 		
       $subModule_RepoName = $subModules_ArrayArray[$i][2]
       $subModule_Branch = $subModules_ArrayArray[$i][3]
       $mainRepoContentJson = (Invoke-WebRequest "https://api.github.com/repos/$subModule_UserName/$subModule_RepoName/commits/$subModule_Branch"        -UseBasicParsing | ConvertFrom-Json)
       $subModules_ArrayArray[$i][3] = $mainRepoContentJson.sha
}

# Copy symbols from the source directory
cmd /c rmdir $symbolsFolder /s /q
cmd /c mkdir $symbolsFolder

if ($pdbPaths -eq $null)
{
       cmd /c .\pdbcpy.cmd $localSourceDir $symbolsFolder
}
else
{
       foreach ($pdbPath in $pdbPaths)
       {
              cmd /c .\pdbcpy.cmd $pdbPath $symbolsFolder
       }
}

# Edit the pdb's with http addresses
.\github-sourceindexer.ps1 -ignoreUnknown -ignore $ignoreArray -sourcesroot $localSourceDir -dbgToolsPath $dbgToolsPath -symbolsFolder $symbolsFolder -userId $repo_userId -repository $repo_name -branch $repo_branch -subModules $subModules_ArrayArray -verbose

# Run symstore on all of the .pdb's
cmd /c rmdir $outputFolder /s /q
cmd /c mkdir $outputFolder
cmd /c "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\symstore.exe" add /compress /r /f $symbolsFolder /s $outputFolder /t SLOBS

# Upload to aws
try 
{
       .\s3upload.ps1 -symStoreFolder $outputFolder

       # Cleanup
       cmd /c rmdir $outputFolder /s /q
       cmd /c rmdir $symbolsFolder /s /q
}
catch
{
       Write-Error "s3upload.ps1 failed"
       
       cmd /c rmdir $outputFolder /s /q
       cmd /c rmdir $symbolsFolder /s /q

       # Run the failure upward to the calling script if there is one
       exit 1
}
