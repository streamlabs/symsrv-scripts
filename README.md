# Symbol/Source Server Indexing and Upload

Entry point is **main.ps1**

* Installs winsdk debugger tools to default location ${env:ProgramFiles(x86)}
* Copies all *.pdb from the project folder to a single, working folder
* Works out each pdb's store key with **symstore.exe /x** and drops the ones the bucket already has
* Edits the remaining pdb's to use http paths using a modified [github-sourceindexer.ps1](https://github.com/Haemoglobin/GitHub-Source-Indexer) script
* Runs microsoft's **symstore.exe** on the .pdb files
* Checks every compressed file is a single, self-contained cabinet before anything leaves the machine
* Uploads output to the s3 bucket using AWS_SYMB_ACCESS_KEY_ID and AWS_SYMB_SECRET_ACCESS_KEY system env vars

**The working directory needs to able to find partner scripts at .\here**

## Skipping symbols the store already has

A pdb's store key is its name plus the signature guid and age the compiler stamped into it, so the
same binary always lands on the same key. Rather than recompressing and reuploading pdb's that are
already there, the script asks the bucket first and only does the expensive work on what is missing.

The lookup fails open - if it cannot reach the bucket, or symstore cannot index, every pdb is
uploaded exactly as it was before. Pass **-forceUpload** to skip the lookup entirely.

Pdb's with an all-F signature are dropped. symstore writes that when it cannot read a signature out
of the file, which is the case for static library compile pdb's - no binary's debug directory points
at one, so nothing can ever look the key up. `vc140.pdb` through `vc143.pdb` are dropped by name for
the same reason. Add more with **-excludePdbNames** (accepts wildcards, e.g. `'moc.pdb,Qt6Example*.pdb'`).

## Very large pdb's

`symstore /compress` spans its cabinet output once a pdb gets big enough, and hands every cabinet in
the set the same filename - so only the last one survives on disk. What reaches the bucket is then a
cabinet that downloads fine and fails to expand on every client, which surfaces much later as a
debugger that keeps asking for a pdb it has already downloaded.

Pdb's over 1 GB are held back from that pass. They are stored uncompressed so symstore still works
out the key and builds the folder, then compressed in place with **makecab** and `MaxDiskSize=0`,
which is what keeps the result in a single cabinet. The store key is the same either way, so nothing
downstream needs to know which path a pdb took.

Every `.pd_` is then checked - cabinet magic, the size the header declares against the real size,
and the spanned set flags - and the run fails instead of uploading one no client could use.

## Debug output

Set the **SYMSRV_DEBUG=1** environment variable, or pass **-debugOutput**, to turn on verbose source
indexing and `aws --debug`. Both are off by default - the aws debug log alone runs to tens of
thousands of lines per build.

# Examples

* *.\main.ps1 -localSourceDir 'C:\github\streamlabs\crash-handler' -repo_userId 'streamlabs' -repo_name 'crash-handler' -repo_branch '912ad9e2e475d0dfd77b6433f5a63621059d4101' -ignoreArray 'awss,awsi'*
* *.\main.ps1 -localSourceDir 'C:\github\streamlabs\obs-studio-node' -repo_userId 'streamlabs' -repo_name 'obs-studio-node' -repo_branch '40bb496b50fa634fbc5f5d6bd3b6b42a0e2a9826' -subModules 'stream-labs,lib-streamlabs-ipc,stream-labs'*
* *main.bat 'workingDir' ".\main.ps1 -localSourceDir 'C:\github\streamlabs\obs-studio' -repo_userId 'streamlabs' -repo_name 'obs-studio-node' -repo_branch '41d1f33c2288bfdad8515841999f6d780295ac0f' -subModules 'plugins/enc-amf,stream-labs,obs-amd-encoder,streamlabs'"*

The submodules parameter needs to know four things. The path it's located at within the project, the username that the repo belongs to, the name of the repo, and the branch used by the project. The version used at compilation time will be deduced by the script, so provide the name of the main branch such as 'master', 'head', 'streamlabs', etc.