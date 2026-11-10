<#
.SYNOPSIS
Import an archived SAP Cloud Integration package into a tenant: the opposite
of cpi-archive.ps1.

.DESCRIPTION
Takes one package from a package repository made by cpi-archive (local folder
or remote git URL, optionally at a tag such as snapshot/20261110-072909) or
from a plain package export .zip, and imports it into the tenant.

By default it imports the full package export, _export/<Package>.zip. With
-FromContent, or when the repository has no export zip, it creates the package
from package.json and uploads every artifact from its unzipped content/ folder
instead.

Optionally it then sets the iFlow externalized parameters from each
configuration.json (-ApplyConfiguration) and deploys the package's artifacts
(-Deploy). Security material (credentials, keys) is never part of an archive;
the names listed in security-refs.tsv are printed so you can create them.

Connection values come from the options, -ServiceKey or the environment
variables CPI_API_URL, CPI_TOKEN_URL, CPI_CLIENT_ID, CPI_CLIENT_SECRET
(or CPI_USER / CPI_PASSWORD for basic auth); options win. The API client needs
write roles (plan "api" with WebToolingWorkspace.Write, and
NodeManager.deploycontent for -Deploy).

Requires Windows PowerShell 5.1 or PowerShell 7+, and Git for Windows for
-GitUrl, -Ref and repositories that store the zip with Git LFS.

.PARAMETER Path
Local source: a package repository folder, a folder of package repositories
(pick one with -Package), or a package export .zip file.

.PARAMETER GitUrl
Remote source: URL of a package repository. It is cloned into a temporary
folder and deleted afterwards.

.PARAMETER Ref
Tag, branch or commit to import instead of the current state, for example
snapshot/20261110-072909. Works with -GitUrl and with a local repository
(-Path), whose working tree is left untouched.

.PARAMETER Package
With -Path pointing at a folder of package repositories: the package to take.

.PARAMETER FromContent
Build the package from package.json and the artifact content/ folders instead
of importing _export/<Package>.zip.

.PARAMETER Overwrite
Replace the package if it already exists on the tenant. Without it, an existing
package stops the import.

.PARAMETER ApplyConfiguration
Set the iFlow externalized parameters from each iflows/<Id>/configuration.json.
The values come from the tenant the archive was made from, so check that they
fit the target tenant.

.PARAMETER Deploy
Deploy the package's artifacts after the import (script collections, value
mappings, message mappings, then iFlows) and wait for the result.

.PARAMETER DeployTimeout
Seconds to wait for each deployment (default 300).

.PARAMETER DryRun
Check the source and the tenant and show what would be done, without changing
anything.

.PARAMETER ServiceKey
Read URL and OAuth data from a BTP service key (JSON, plan "api"). Alias -k.

.PARAMETER ApiUrl
API base URL (CPI_API_URL).

.PARAMETER TokenUrl
OAuth token URL (CPI_TOKEN_URL).

.PARAMETER ClientId
OAuth client id (CPI_CLIENT_ID).

.PARAMETER ClientSecret
OAuth client secret (CPI_CLIENT_SECRET); ends up in the shell history,
prefer the variable or the service key.

.PARAMETER Login
Log in as a user in the browser (OAuth authorization code) instead of using
client credentials.

.PARAMETER LoginPort
Local port for the login redirect (default 8765); the client must allow
http://localhost:PORT/callback.

.EXAMPLE
.\cpi-import.ps1 -k qa-key.json -Path C:\cpi\cpi-dev\MyPackage

Imports the package from a local package repository, as it is checked out.

.EXAMPLE
.\cpi-import.ps1 -k qa-key.json -GitUrl https://gitlab.example.com/archive/mypackage.git -Ref snapshot/20261110-072909 -Overwrite -Deploy

Imports an older snapshot from the remote repository, replaces the package on
the tenant and deploys it.

.EXAMPLE
.\cpi-import.ps1 -k qa-key.json -Path .\MyPackage.zip -DryRun
#>
#Requires -Version 5.1
param(
  [string]$Path,
  [string]$GitUrl,
  [string]$Ref,
  [Alias('p')][string]$Package,
  [switch]$FromContent,
  [switch]$Overwrite,
  [switch]$ApplyConfiguration,
  [switch]$Deploy,
  [int]$DeployTimeout = 300,
  [switch]$DryRun,
  [Alias('k')][string]$ServiceKey,
  [string]$ApiUrl,
  [string]$TokenUrl,
  [string]$ClientId,
  [string]$ClientSecret,
  [switch]$Login,
  [int]$LoginPort = 8765,
  [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar slows uploads down a lot

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }

function Write-Log([string]$Message) { [Console]::Error.WriteLine($Message) }
function Write-Warn([string]$Message) { [Console]::Error.WriteLine("WARN: $Message") }
function Stop-Import([string]$Message) { throw $Message }

# entity set : folder in the archive. Also the deploy order: iFlows use the
# script collections and mappings, so they come last.
$script:Types = @(
  'ScriptCollectionDesigntimeArtifacts:scripts'
  'ValueMappingDesigntimeArtifacts:valuemappings'
  'MessageMappingDesigntimeArtifacts:mappings'
  'IntegrationDesigntimeArtifacts:iflows'
)

$script:Utf8 = New-Object System.Text.UTF8Encoding $false
function Read-TextFile([string]$File) { [IO.File]::ReadAllText($File, $script:Utf8) }
function Read-JsonFile([string]$File) { Read-TextFile $File | ConvertFrom-Json }

function Remove-PathTree([string]$Target) {
  if ([IO.Directory]::Exists($Target)) {
    # git makes its object files read-only, which blocks Directory.Delete.
    foreach ($f in [IO.Directory]::GetFiles($Target, '*', [IO.SearchOption]::AllDirectories)) {
      [IO.File]::SetAttributes($f, [IO.FileAttributes]::Normal)
    }
    [IO.Directory]::Delete($Target, $true)
  } elseif ([IO.File]::Exists($Target)) { [IO.File]::Delete($Target) }
}

# JSON request body from an ordered dictionary of strings. Built by hand
# because ConvertTo-Json is slow on multi-megabyte base64 strings in
# Windows PowerShell 5.1.
function ConvertTo-JsonBody($Fields) {
  $parts = foreach ($k in $Fields.Keys) {
    $v = $Fields[$k]
    if ($null -eq $v) { "`"$k`":null" }
    else {
      $s = [regex]::Replace([string]$v, '[\\"\x00-\x1f]', {
          param($m)
          switch ([int][char]$m.Value) {
            34 { '\"' } 92 { '\\' } 10 { '\n' } 13 { '\r' } 9 { '\t' }
            default { '\u{0:x4}' -f [int][char]$m.Value }
          }
        })
      "`"$k`":`"$s`""
    }
  }
  return '{' + ($parts -join ',') + '}'
}

# --- authentication (same as cpi-archive.ps1) -------------------------------
function Request-Token([hashtable]$Form) {
  $pair = "$($script:Cfg.CPI_CLIENT_ID):$($script:Cfg.CPI_CLIENT_SECRET)"
  $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
  try {
    $resp = Invoke-RestMethod -Method Post -Uri $script:Cfg.CPI_TOKEN_URL -UseBasicParsing `
      -Headers @{ Authorization = "Basic $basic" } -Body $Form -ContentType 'application/x-www-form-urlencoded'
  } catch {
    Write-Warn "token request failed: $($_.Exception.Message)"
    return $false
  }
  if (-not $resp.access_token) { Stop-Import 'no access_token in the token response' }
  $expires = 3600
  if ($resp.expires_in) { $expires = [int]$resp.expires_in }
  $script:TokenExp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $expires
  if ($resp.refresh_token) { $script:RefreshToken = [string]$resp.refresh_token }
  $script:AuthHeader = "Bearer $($resp.access_token)"
  return $true
}

function Get-QueryParam([string]$Url, [string]$Name) {
  $m = [regex]::Match($Url, '.*[?&]' + [regex]::Escape($Name) + '=([^&#]*)')
  if (-not $m.Success) { return '' }
  return [Uri]::UnescapeDataString($m.Groups[1].Value.Replace('+', ' '))
}

function Invoke-BrowserLogin {
  $redirect = "http://localhost:$LoginPort/callback"
  $bytes = New-Object byte[] 16
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $state = -join ($bytes | ForEach-Object { $_.ToString('x2') })
  $authBase = $script:Cfg.CPI_AUTH_URL
  if (-not $authBase) { $authBase = ($script:Cfg.CPI_TOKEN_URL -replace '/oauth/token$', '') + '/oauth/authorize' }
  $authUrl = $authBase + '?response_type=code' +
    '&client_id=' + [Uri]::EscapeDataString($script:Cfg.CPI_CLIENT_ID) +
    '&redirect_uri=' + [Uri]::EscapeDataString($redirect) + "&state=$state"

  $listener = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $LoginPort
  try { $listener.Start() } catch { Stop-Import "cannot listen on port $LoginPort (in use? try -LoginPort)" }
  try {
    Write-Log 'Log in with your browser (waiting up to 5 minutes):'
    Write-Log "  $authUrl"
    try { Start-Process $authUrl } catch { }
    $deadline = (Get-Date).AddMinutes(5)
    $target = $null
    while (-not $target) {
      while (-not $listener.Pending()) {
        if ((Get-Date) -gt $deadline) { Stop-Import "no login redirect received on $redirect within 5 minutes" }
        Start-Sleep -Milliseconds 200
      }
      $client = $listener.AcceptTcpClient()
      try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
        $line = $reader.ReadLine()
        while ($reader.ReadLine()) { }
        $parts = "$line" -split ' '
        if ($parts.Count -ge 2 -and $parts[0] -eq 'GET' -and $parts[1].StartsWith('/callback?')) {
          $target = $parts[1]
          $status = '200 OK'
          $body = 'cpi-import.ps1: login received, you can close this tab.'
        } else {
          $status = '404 Not Found'
          $body = 'not found'
        }
        $response = [Text.Encoding]::UTF8.GetBytes("HTTP/1.1 $status`r`nContent-Type: text/plain; charset=utf-8`r`n" +
          "Content-Length: $([Text.Encoding]::UTF8.GetByteCount($body))`r`nConnection: close`r`n`r`n$body")
        $stream.Write($response, 0, $response.Length)
      } catch {
        # idle or broken connection, wait for the next one
      } finally {
        $client.Close()
      }
    }
  } finally {
    $listener.Stop()
  }

  if ((Get-QueryParam $target 'state') -ne $state) { Stop-Import 'login redirect has a wrong state, try again' }
  $code = Get-QueryParam $target 'code'
  if (-not $code) {
    Stop-Import "login failed: $(Get-QueryParam $target 'error') $(Get-QueryParam $target 'error_description')"
  }
  if (-not (Request-Token @{ grant_type = 'authorization_code'; code = $code; redirect_uri = $redirect })) {
    Stop-Import "token request to $($script:Cfg.CPI_TOKEN_URL) failed"
  }
  Write-Log 'Logged in'
}

function Update-Token {
  if ($script:AuthMode -eq 'basic') {
    if (-not $script:AuthHeader) {
      $pair = "$($script:Cfg.CPI_USER):$($script:Cfg.CPI_PASSWORD)"
      $script:AuthHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    }
    return
  }
  if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt $script:TokenExp - 300) { return }
  if ($script:AuthMode -eq 'client') {
    if (-not (Request-Token @{ grant_type = 'client_credentials' })) {
      Stop-Import "token request to $($script:Cfg.CPI_TOKEN_URL) failed"
    }
  } elseif ($script:RefreshToken -and
    (Request-Token @{ grant_type = 'refresh_token'; refresh_token = $script:RefreshToken })) {
    return
  } else {
    Invoke-BrowserLogin
  }
}

# --- API --------------------------------------------------------------------
function Get-ResponseHeader($Response, [string]$Name) {
  if (-not $Response) { return '' }
  if ($Response -is [Net.WebResponse]) { return [string]$Response.Headers[$Name] }
  $values = $null
  if ($Response.Headers.TryGetValues($Name, [ref]$values)) { return ($values -join ',') }
  return ''
}

function Get-ErrorText($ErrorRecord) {
  if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { return $ErrorRecord.ErrorDetails.Message }
  $resp = $ErrorRecord.Exception.Response
  if ($resp -is [Net.WebResponse]) {
    try { return (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch { }
  }
  return ''
}

# OData error -> its message text; anything else -> the start of the body.
function Format-ApiError($Result) {
  $text = [string]$Result.Content
  try {
    $msg = ($text | ConvertFrom-Json).error.message
    if ($msg.value) { $text = [string]$msg.value } elseif ($msg) { $text = [string]$msg }
  } catch { }
  $text = [regex]::Replace($text, '\s+', ' ').Trim()
  if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
  if ($text) { return "HTTP $($Result.Status): $text" }
  return "HTTP $($Result.Status)"
}

# Fetched only when the tenant asks for it (403 with "X-CSRF-Token: Required");
# OAuth clients usually don't need it.
function Update-Csrf {
  try {
    $r = Invoke-WebRequest -Uri "$($script:Api)/api/v1/" -UseBasicParsing -WebSession $script:Session `
      -Headers @{ Authorization = $script:AuthHeader; Accept = 'application/json'; 'X-CSRF-Token' = 'Fetch' }
    $script:Csrf = (@($r.Headers['X-CSRF-Token']) -join ',')
  } catch {
    Write-Warn "could not fetch a CSRF token: $($_.Exception.Message)"
  }
}

# Calls the API and returns @{ Status; Content }. Throws only when no HTTP
# response came back at all; callers check the status.
function Invoke-Api([string]$Method, [string]$ApiPath, [string]$Body) {
  Update-Token
  $url = "$($script:Api)$ApiPath"
  for ($attempt = 0; $attempt -lt 2; $attempt++) {
    $headers = @{ Authorization = $script:AuthHeader; Accept = 'application/json' }
    if ($Method -ne 'GET' -and $script:Csrf) { $headers['X-CSRF-Token'] = $script:Csrf }
    $req = @{
      Method = $Method; Uri = $url; Headers = $headers; UseBasicParsing = $true
      WebSession = $script:Session; TimeoutSec = 900
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
      $req.Body = [Text.Encoding]::UTF8.GetBytes($Body)
      $req.ContentType = 'application/json; charset=utf-8'
    }
    try {
      $r = Invoke-WebRequest @req
      $content = $r.Content
      if ($content -is [byte[]]) { $content = $script:Utf8.GetString($content) }
      return [pscustomobject]@{ Status = [int]$r.StatusCode; Content = [string]$content }
    } catch {
      $resp = $_.Exception.Response
      if (-not $resp) { throw "$Method $url failed: $($_.Exception.Message)" }
      $status = [int]$resp.StatusCode
      if ($status -eq 403 -and $attempt -eq 0 -and $Method -ne 'GET' -and
        (Get-ResponseHeader $resp 'X-CSRF-Token') -eq 'Required') {
        Update-Csrf
        continue
      }
      return [pscustomobject]@{ Status = $status; Content = (Get-ErrorText $_) }
    }
  }
}

# Results of a list call, following paging. Throws on failure.
function Get-ODataList([string]$ApiPath) {
  $rows = New-Object System.Collections.Generic.List[object]
  $next = $ApiPath
  while ($next) {
    $r = Invoke-Api GET $next
    if ($r.Status -ne 200) { throw "GET $next failed: $(Format-ApiError $r)" }
    $doc = $r.Content | ConvertFrom-Json
    foreach ($row in @($doc.d.results)) { if ($null -ne $row) { $rows.Add($row) } }
    $next = [string]$doc.d.__next
    if ($next -like 'http*') { $next = $next.Substring($script:Api.Length) }
    elseif ($next -and -not $next.StartsWith('/')) { $next = "/api/v1/$next" }
  }
  return , $rows
}

function Test-ApiEntity([string]$ApiPath) {
  $r = Invoke-Api GET $ApiPath
  if ($r.Status -eq 200) { return $true }
  if ($r.Status -eq 404) { return $false }
  throw "GET $ApiPath failed: $(Format-ApiError $r)"
}

function Get-OdataKey([string]$Value) { [Uri]::EscapeDataString($Value.Replace("'", "''")) }

# --- git --------------------------------------------------------------------
function Invoke-Git([string[]]$GitArgs, [switch]$Quiet) {
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Quiet) { $out = & git @GitArgs 2>$null } else { $out = & git @GitArgs }
  } finally {
    $ErrorActionPreference = $eap
  }
  $script:GitExit = $LASTEXITCODE
  return $out
}

function Invoke-GitOrThrow([string[]]$GitArgs) {
  Invoke-Git $GitArgs | Out-Null
  if ($script:GitExit) { throw "git $($GitArgs -join ' ') failed" }
}

function Assert-Git {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Stop-Import 'git is not installed (install Git for Windows)' }
}

function Test-LfsPointer([string]$File) {
  $buf = New-Object byte[] 40
  $fs = [IO.File]::OpenRead($File)
  try { $n = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Close() }
  return ([Text.Encoding]::ASCII.GetString($buf, 0, $n)).StartsWith('version https://git-lfs')
}

# --- source -----------------------------------------------------------------
# Package id from the export zip: the ContentPackage entry of resources.cnt.
function Get-ZipPackageId([string]$Zip) {
  $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
  try {
    $entry = $archive.GetEntry('resources.cnt')
    if (-not $entry) { Stop-Import "$Zip is not a CPI package export (no resources.cnt)" }
    $reader = New-Object IO.StreamReader($entry.Open())
    try { $b64 = $reader.ReadToEnd() } finally { $reader.Close() }
  } finally {
    $archive.Dispose()
  }
  $doc = $script:Utf8.GetString([Convert]::FromBase64String($b64.Trim())) | ConvertFrom-Json
  $pkg = @($doc.resources | Where-Object { $_.resourceType -eq 'ContentPackage' })
  if (-not $pkg.Count) { Stop-Import "$Zip has no package entry in resources.cnt" }
  return [string]$pkg[0].uniqueId
}

# Finds the package repository below a folder that holds several of them.
function Resolve-RepoFolder([string]$Folder) {
  if (Test-Path -LiteralPath (Join-Path $Folder 'package.json')) {
    if ($Package) { Write-Warn "-Package $Package ignored: $Folder is a package repository itself" }
    return $Folder
  }
  if ($Package) {
    $sub = Join-Path $Folder $Package
    if (-not (Test-Path -LiteralPath (Join-Path $sub 'package.json'))) { Stop-Import "no package repository $sub" }
    return $sub
  }
  $repos = @(Get-ChildItem -LiteralPath $Folder -Directory |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'package.json') })
  if ($repos.Count -eq 1) { return $repos[0].FullName }
  if ($repos.Count -gt 1) {
    Stop-Import "$Folder holds several package repositories ($(($repos | ForEach-Object Name) -join ', ')); pick one with -Package"
  }
  Stop-Import "$Folder is neither a package repository (no package.json) nor a folder of them"
}

# Returns @{ RepoDir; Zip; PackageId; Label }. RepoDir is $null for a plain zip.
function Resolve-Source {
  $src = @{ RepoDir = $null; Zip = $null; PackageId = $null; Label = '' }
  $checkout = Join-Path $script:Tmp 'src'

  if ($GitUrl) {
    Assert-Git
    Write-Log "Cloning $GitUrl$(if ($Ref) { " at $Ref" })"
    $clone = @('-c', 'core.longpaths=true', 'clone', '-q', '-c', 'core.longpaths=true')
    if ($Ref) { Invoke-Git -Quiet ($clone + @('--depth', '1', '--branch', $Ref, $GitUrl, $checkout)) | Out-Null }
    else { Invoke-Git -Quiet ($clone + @('--depth', '1', $GitUrl, $checkout)) | Out-Null }
    if ($script:GitExit -and $Ref) {
      # --branch only takes branches and tags; a commit needs the full history.
      Remove-PathTree $checkout
      Invoke-GitOrThrow ($clone + @($GitUrl, $checkout))
      Invoke-Git -Quiet @('-C', $checkout, 'checkout', '-q', $Ref) | Out-Null
      if ($script:GitExit) { Stop-Import "$Ref not found in $GitUrl" }
    } elseif ($script:GitExit) {
      Stop-Import "cloning $GitUrl failed (wrong URL or no access?)"
    }
    $src.RepoDir = $checkout
    $src.Label = $GitUrl
    if ($Ref) { $src.Label += " at $Ref" }
  } else {
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($PWD.ProviderPath, ($Path -replace '^~', $HOME)))
    if ([IO.File]::Exists($full)) {
      if ($Ref) { Stop-Import '-Ref needs a repository, not a zip file' }
      $src.Zip = $full
      $src.PackageId = Get-ZipPackageId $full
      $src.Label = $full
      return $src
    }
    if (-not [IO.Directory]::Exists($full)) { Stop-Import "$Path does not exist" }
    $repo = Resolve-RepoFolder $full
    $src.Label = $repo
    if ($Ref) {
      # A temporary worktree checks out the ref without touching the user's files.
      Assert-Git
      Invoke-Git -Quiet @('-C', $repo, 'rev-parse', '--verify', '-q', "$Ref^{commit}") | Out-Null
      if ($script:GitExit) { Stop-Import "$Ref not found in $repo" }
      Write-Log "Checking out $Ref of $repo"
      Invoke-GitOrThrow @('-c', 'core.longpaths=true', '-C', $repo, 'worktree', 'add', '-q', '--detach', $checkout, $Ref)
      $script:Worktree = @{ Repo = $repo; Dir = $checkout }
      $src.RepoDir = $checkout
      $src.Label = "$repo at $Ref"
    } else {
      if (Test-Path -LiteralPath (Join-Path $repo '.git')) {
        $dirty = Invoke-Git -Quiet @('-C', $repo, 'status', '--porcelain')
        if ($dirty) { Write-Warn "$repo has uncommitted changes; they are imported as they are" }
      }
      $src.RepoDir = $repo
    }
  }

  $pkgFile = Join-Path $src.RepoDir 'package.json'
  if (-not (Test-Path -LiteralPath $pkgFile)) { Stop-Import "$($src.Label) is not a package repository (no package.json)" }
  $src.PackageId = [string](Read-JsonFile $pkgFile).Id
  if (-not $src.PackageId) { Stop-Import "$pkgFile has no Id" }

  $zip = Join-Path (Join-Path $src.RepoDir '_export') "$($src.PackageId).zip"
  if (Test-Path -LiteralPath $zip) {
    if (Test-LfsPointer $zip) {
      Assert-Git
      Write-Log 'Fetching the package zip from Git LFS'
      Invoke-Git @('-C', $src.RepoDir, 'lfs', 'pull', '--include', "_export/$($src.PackageId).zip") | Out-Null
      if ($script:GitExit -or (Test-LfsPointer $zip)) {
        Stop-Import "_export/$($src.PackageId).zip is a Git LFS pointer and git lfs pull failed (git-lfs installed?)"
      }
    }
    $src.Zip = $zip
  }
  return $src
}

# Artifacts in the repository, in deploy order: list of @{ Entity; Folder; Id; Name; Dir }.
function Get-RepoArtifacts([string]$RepoDir) {
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($entry in $script:Types) {
    $entity, $folder = $entry -split ':'
    $base = Join-Path $RepoDir $folder
    if (-not (Test-Path -LiteralPath $base)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name)) {
      $meta = Join-Path $d.FullName 'artifact.json'
      if (-not (Test-Path -LiteralPath $meta)) { continue }
      $a = Read-JsonFile $meta
      $id = [string]$a.Id
      if (-not $id) { $id = $d.Name }
      $name = [string]$a.Name
      if (-not $name) { $name = $id }
      $list.Add(@{ Entity = $entity; Folder = $folder; Id = $id; Name = $name; Dir = $d.FullName })
    }
  }
  return , $list
}

# Artifacts of the package on the tenant, in deploy order.
function Get-TenantArtifacts([string]$PackageId) {
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($entry in $script:Types) {
    $entity, $folder = $entry -split ':'
    foreach ($row in (Get-ODataList "/api/v1/IntegrationPackages('$PackageId')/$entity")) {
      $list.Add(@{ Entity = $entity; Folder = $folder; Id = [string]$row.Id; Name = [string]$row.Name })
    }
  }
  return , $list
}

# --- import -----------------------------------------------------------------
# Returns $null on success, or the conflict message when -Overwrite was
# refused: CPI only overwrites a package whose artifacts came from the same
# export; one created by hand (or with -FromContent) conflicts on artifact ids.
function Import-PackageZip([string]$Zip, [string]$PackageId, [bool]$Exists) {
  $size = (Get-Item -LiteralPath $Zip).Length
  Write-Log "Importing $([IO.Path]::GetFileName($Zip)) ($([math]::Round($size / 1KB)) KB)"
  $body = '{"PackageContent":"' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($Zip)) + '"}'
  $query = ''
  if ($Exists) { $query = '?Overwrite=true' }
  $r = Invoke-Api POST "/api/v1/IntegrationPackages$query" $body
  if ($r.Status -eq 409 -and $Exists) { return (Format-ApiError $r) }
  if ($r.Status -ge 300) { Stop-Import "import failed: $(Format-ApiError $r)" }
  Write-Log '  imported'
  return $null
}

# Creates the package from package.json and uploads each artifact's content/.
# Returns the number of artifacts that failed.
function Import-PackageContent($Src, [bool]$Exists) {
  $pkg = Read-JsonFile (Join-Path $Src.RepoDir 'package.json')
  if ($Exists) {
    Write-Log "Package $($Src.PackageId) exists, updating its artifacts"
  } else {
    Write-Log "Creating package $($Src.PackageId)"
    $fields = [ordered]@{ Id = $Src.PackageId }
    foreach ($k in 'Name', 'ShortText', 'Description', 'Version', 'Vendor', 'Keywords', 'Countries',
      'Industries', 'LineOfBusiness', 'Products') {
      if ($pkg.$k) { $fields[$k] = [string]$pkg.$k }
    }
    if (-not $fields['Name']) { $fields['Name'] = $Src.PackageId }
    if (-not $fields['ShortText']) { $fields['ShortText'] = $fields['Name'] }
    $r = Invoke-Api POST '/api/v1/IntegrationPackages' (ConvertTo-JsonBody $fields)
    if ($r.Status -ge 300) { Stop-Import "creating package $($Src.PackageId) failed: $(Format-ApiError $r)" }
  }

  $failed = 0
  $artifacts = Get-RepoArtifacts $Src.RepoDir
  if (-not $artifacts.Count) { Write-Warn 'the repository has no artifacts' }
  $zip = Join-Path $script:Tmp 'artifact.zip'
  foreach ($a in $artifacts) {
    $content = Join-Path $a.Dir 'content'
    if (-not (Test-Path -LiteralPath $content)) {
      Write-Warn "  $($a.Folder)/$($a.Id): no content folder, skipped"
      $failed++
      continue
    }
    Remove-PathTree $zip
    [IO.Compression.ZipFile]::CreateFromDirectory($content, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
    $key = "/api/v1/$($a.Entity)(Id='$(Get-OdataKey $a.Id)',Version='active')"
    $update = $Exists -and (Test-ApiEntity $key)
    if ($update) {
      $r = Invoke-Api PUT $key (ConvertTo-JsonBody ([ordered]@{ Name = $a.Name; ArtifactContent = $b64 }))
    } else {
      $r = Invoke-Api POST "/api/v1/$($a.Entity)" (ConvertTo-JsonBody ([ordered]@{
            Name = $a.Name; Id = $a.Id; PackageId = $Src.PackageId; ArtifactContent = $b64 }))
    }
    if ($r.Status -ge 300) {
      Write-Warn "  $($a.Folder)/$($a.Id): $(Format-ApiError $r)"
      $failed++
    } elseif ($update) { Write-Log "  $($a.Folder)/$($a.Id) updated" }
    else { Write-Log "  $($a.Folder)/$($a.Id) created" }
  }

  if ($Exists) {
    $known = @($artifacts | ForEach-Object { "$($_.Entity)/$($_.Id)" })
    foreach ($t in (Get-TenantArtifacts $Src.PackageId)) {
      if ($known -cnotcontains "$($t.Entity)/$($t.Id)") {
        Write-Warn "  $($t.Folder)/$($t.Id) is on the tenant but not in the archive; left in place"
      }
    }
  }
  return $failed
}

# Sets the externalized parameters from iflows/<Id>/configuration.json.
# Returns the number of iFlows with failures.
function Set-IflowConfiguration([string]$RepoDir, $TenantArtifacts) {
  $failed = 0
  foreach ($a in $TenantArtifacts) {
    if ($a.Folder -ne 'iflows') { continue }
    $file = Join-Path (Join-Path (Join-Path $RepoDir 'iflows') $a.Id) 'configuration.json'
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $params = @(Read-JsonFile $file | ForEach-Object { $_ })
    $set = 0
    $errors = 0
    foreach ($p in $params) {
      if ($null -eq $p -or $null -eq $p.ParameterValue) { continue }
      $url = "/api/v1/IntegrationDesigntimeArtifacts(Id='$(Get-OdataKey $a.Id)',Version='active')" +
        "/`$links/Configurations('$(Get-OdataKey ([string]$p.ParameterKey))')"
      $fields = [ordered]@{ ParameterValue = [string]$p.ParameterValue }
      if ($p.DataType) { $fields['DataType'] = [string]$p.DataType }
      $r = Invoke-Api PUT $url (ConvertTo-JsonBody $fields)
      if ($r.Status -ge 300) {
        Write-Warn "  iflows/$($a.Id) parameter $($p.ParameterKey): $(Format-ApiError $r)"
        $errors++
      } else { $set++ }
    }
    Write-Log "  iflows/$($a.Id): $set parameter(s) set"
    if ($errors) { $failed++ }
  }
  return $failed
}

# Deploys one artifact and waits for its runtime status. Returns $true on success.
function Publish-Artifact($Artifact) {
  $op = 'Deploy' + ($Artifact.Entity -replace 's$', '')
  $id = Get-OdataKey $Artifact.Id
  $r = Invoke-Api POST "/api/v1/$op`?Id='$id'&Version='active'"
  if ($r.Status -ge 300) {
    Write-Warn "  $($Artifact.Folder)/$($Artifact.Id): deploy failed: $(Format-ApiError $r)"
    return $false
  }
  $deadline = (Get-Date).AddSeconds($DeployTimeout)
  $status = ''
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $r = Invoke-Api GET "/api/v1/IntegrationRuntimeArtifacts('$id')"
    if ($r.Status -eq 200) {
      $status = [string]($r.Content | ConvertFrom-Json).d.Status
      if ($status -eq 'STARTED') {
        Write-Log "  $($Artifact.Folder)/$($Artifact.Id): started"
        return $true
      }
      if ($status -eq 'ERROR') {
        $info = Invoke-Api GET "/api/v1/IntegrationRuntimeArtifacts('$id')/ErrorInformation/`$value"
        $text = [string]$info.Content
        try {
          $doc = $text | ConvertFrom-Json
          if ($doc.parameter) { $text = ($doc.parameter -join '; ') } elseif ($doc.message) { $text = [string]$doc.message.subsystemName + ' ' + $text }
        } catch { }
        if ($text.Length -gt 500) { $text = $text.Substring(0, 500) + '...' }
        Write-Warn "  $($Artifact.Folder)/$($Artifact.Id): deployment error: $text"
        return $false
      }
    }
  }
  Write-Warn "  $($Artifact.Folder)/$($Artifact.Id): not started after $DeployTimeout s (status: $(if ($status) { $status } else { 'unknown' }))"
  return $false
}

# --- main -------------------------------------------------------------------
$exitCode = 0
$script:Tmp = $null
$script:Worktree = $null
try {
  if ([bool]$Path -eq [bool]$GitUrl) { Stop-Import 'give the source with either -Path or -GitUrl' }
  if ($DeployTimeout -lt 10) { Stop-Import '-DeployTimeout must be at least 10 seconds' }
  foreach ($assembly in 'System.IO.Compression', 'System.IO.Compression.FileSystem') {
    try { Add-Type -AssemblyName $assembly } catch { }
  }
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  }

  # Connection: environment, then service key, then options.
  $script:Cfg = @{}
  foreach ($name in 'CPI_API_URL', 'CPI_TOKEN_URL', 'CPI_CLIENT_ID', 'CPI_CLIENT_SECRET', 'CPI_USER', 'CPI_PASSWORD', 'CPI_AUTH_URL') {
    $script:Cfg[$name] = [Environment]::GetEnvironmentVariable($name)
  }
  if ($ServiceKey) {
    $oauth = (Read-JsonFile (Resolve-Path -LiteralPath $ServiceKey).ProviderPath).oauth
    $script:Cfg.CPI_API_URL = [string]$oauth.url
    $script:Cfg.CPI_TOKEN_URL = [string]$oauth.tokenurl
    $script:Cfg.CPI_CLIENT_ID = [string]$oauth.clientid
    $script:Cfg.CPI_CLIENT_SECRET = [string]$oauth.clientsecret
    $script:Cfg.CPI_AUTH_URL = [string]$oauth.authorizationurl
  }
  if ($ApiUrl) { $script:Cfg.CPI_API_URL = $ApiUrl }
  if ($TokenUrl) { $script:Cfg.CPI_TOKEN_URL = $TokenUrl }
  if ($ClientId) { $script:Cfg.CPI_CLIENT_ID = $ClientId }
  if ($ClientSecret) { $script:Cfg.CPI_CLIENT_SECRET = $ClientSecret }

  if ($Login) { $script:AuthMode = 'login' }
  elseif ($script:Cfg.CPI_USER) { $script:AuthMode = 'basic' }
  else { $script:AuthMode = 'client' }
  if (-not $script:Cfg.CPI_API_URL) { Stop-Import 'set CPI_API_URL, -ApiUrl or -ServiceKey' }
  if ($script:AuthMode -eq 'basic') {
    if (-not $script:Cfg.CPI_PASSWORD) { Stop-Import 'set CPI_PASSWORD' }
  } else {
    if (-not $script:Cfg.CPI_TOKEN_URL) { Stop-Import 'set CPI_TOKEN_URL or -TokenUrl (or CPI_USER/CPI_PASSWORD)' }
    if (-not $script:Cfg.CPI_CLIENT_ID) { Stop-Import 'set CPI_CLIENT_ID or -ClientId' }
    if (-not $script:Cfg.CPI_CLIENT_SECRET) { Stop-Import 'set CPI_CLIENT_SECRET or -ClientSecret' }
  }
  $script:Api = $script:Cfg.CPI_API_URL.TrimEnd('/')
  $script:TenantHost = ([regex]::Match($script:Api, '^[^:]+://([^/]+)')).Groups[1].Value
  $script:AuthHeader = $null
  $script:TokenExp = 0
  $script:RefreshToken = $null
  $script:Csrf = $null
  $script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

  # Short folder in %TEMP%: iFlow content paths are long.
  $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('cpi-import-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  [void][IO.Directory]::CreateDirectory($script:Tmp)

  # --- source ---------------------------------------------------------------
  $src = Resolve-Source
  $packageId = $src.PackageId
  if ($packageId -cnotmatch '^[A-Za-z0-9_.-]+$') { Stop-Import "unexpected package id '$packageId'" }
  $useContent = [bool]$FromContent
  if (-not $src.RepoDir) {
    if ($FromContent) { Stop-Import '-FromContent needs a package repository, not a zip file' }
    if ($ApplyConfiguration) { Stop-Import '-ApplyConfiguration needs a package repository, not a zip file' }
  } elseif (-not $src.Zip -and -not $useContent) {
    Write-Log "No _export/$packageId.zip in the repository, building the package from the artifact folders"
    $useContent = $true
  }

  # --- target ---------------------------------------------------------------
  Update-Token
  $exists = Test-ApiEntity "/api/v1/IntegrationPackages('$packageId')"
  $how = if ($useContent) { 'from the artifact folders' } else { 'from the package export zip' }
  Write-Log "Package $packageId from $($src.Label)"
  Write-Log "  to $($script:TenantHost), $how"
  if ($exists) {
    if ($Overwrite) { Write-Log '  the package exists on the tenant and will be replaced' }
    elseif (-not $DryRun) { Stop-Import "package $packageId already exists on $($script:TenantHost); use -Overwrite to replace it" }
    else { Write-Warn "the package exists on the tenant; the import would stop without -Overwrite" }
  }

  if ($DryRun) {
    if ($src.RepoDir) {
      foreach ($a in (Get-RepoArtifacts $src.RepoDir)) { Write-Log "  $($a.Folder)/$($a.Id)" }
    }
    $steps = @('import')
    if ($ApplyConfiguration) { $steps += 'set iFlow parameters' }
    if ($Deploy) { $steps += 'deploy' }
    Write-Log "Dry run: would $($steps -join ', then '). Nothing was changed."
    exit 0
  }

  # --- import, configure, deploy --------------------------------------------
  $failures = 0
  if ($useContent) { $failures += Import-PackageContent $src $exists }
  else {
    $conflict = Import-PackageZip $src.Zip $packageId $exists
    if ($conflict -and $src.RepoDir) {
      Write-Warn "the tenant refused to overwrite the package ($conflict)"
      Write-Log 'Updating the artifacts one by one from their folders instead'
      $failures += Import-PackageContent $src $true
    } elseif ($conflict) {
      Stop-Import ("overwrite refused, $conflict. The package on the tenant was not created from this export; " +
        'import from the package repository instead (it updates the artifacts one by one), or delete the package on the tenant first')
    }
  }

  $tenantArtifacts = $null
  if ($ApplyConfiguration -or $Deploy) { $tenantArtifacts = Get-TenantArtifacts $packageId }

  if ($ApplyConfiguration) {
    Write-Log 'Setting iFlow externalized parameters'
    $failures += Set-IflowConfiguration $src.RepoDir $tenantArtifacts
  }

  if ($Deploy) {
    Write-Log "Deploying $($tenantArtifacts.Count) artifact(s)"
    foreach ($a in $tenantArtifacts) {
      if (-not (Publish-Artifact $a)) { $failures++ }
    }
  }

  # Security material is not in the archive; list what the iFlows expect.
  if ($src.RepoDir -and (Test-Path -LiteralPath (Join-Path $src.RepoDir 'iflows'))) {
    $refs = @(Get-ChildItem -LiteralPath (Join-Path $src.RepoDir 'iflows') -Recurse -Filter 'security-refs.tsv' |
        ForEach-Object { (Read-TextFile $_.FullName) -split "`n" } | Where-Object { $_ } |
        ForEach-Object { ($_ -split "`t")[1] } | Sort-Object -Unique)
    if ($refs.Count) {
      Write-Log 'Security material the iFlows refer to (create it on the tenant if missing):'
      foreach ($r in $refs) { Write-Log "  $r" }
    }
  }

  if ($failures) {
    Write-Warn "done with $failures failure(s), see the warnings above"
    $exitCode = 1
  } else {
    Write-Log "Done: $packageId is on $($script:TenantHost)"
  }
} catch {
  [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
  $exitCode = 1
} finally {
  if ($script:Worktree) {
    Invoke-Git -Quiet @('-C', $script:Worktree.Repo, 'worktree', 'remove', '--force', $script:Worktree.Dir) | Out-Null
    Invoke-Git -Quiet @('-C', $script:Worktree.Repo, 'worktree', 'prune') | Out-Null
  }
  if ($script:Tmp) {
    try { Remove-PathTree $script:Tmp } catch { Write-Warn "could not remove $($script:Tmp)" }
  }
}
exit $exitCode
