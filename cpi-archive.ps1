<#
.SYNOPSIS
Snapshot SAP Cloud Integration packages into git repositories, one repository
per package (<Dir>\<PackageId>\).

.DESCRIPTION
PowerShell version of cpi-archive.sh with the same options, the same archive
layout and byte-identical files, so one archive can be updated from Linux and
Windows.

Per package it stores the package metadata, a README.md made from it, the full
package export (.zip),
every design-time artifact (iFlows, value mappings, script collections,
message mappings) unzipped, and for iFlows the configured externalized
parameters plus the names of referenced security material.
A run that changes a package becomes one commit and one annotated tag in
that package's repository.

Connection values come from the options, -ServiceKey or the environment
variables CPI_API_URL, CPI_TOKEN_URL, CPI_CLIENT_ID, CPI_CLIENT_SECRET
(or CPI_USER / CPI_PASSWORD for basic auth); options win.

Requires Windows PowerShell 5.1 or PowerShell 7+, and Git for Windows
(it includes git-lfs for -Lfs).

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

.PARAMETER Dir
Folder for the package repositories (default: the current folder); each
package goes to Dir\<PackageId>\. Alias -d.

.PARAMETER Package
Packages to archive, e.g. -Package A,B (default: all packages). Alias -p.

.PARAMETER GitName
Commit author name (CPI_GIT_NAME; default: git's user.name).

.PARAMETER GitEmail
Commit author email (CPI_GIT_EMAIL; default: git's user.email).

.PARAMETER Remote
Set origin of a package's repository: -Remote PKG=URL,PKG2=URL2. With exactly
one -Package, -Remote URL is enough.

.PARAMETER Push
Push each repository's branch and tags to its origin.

.PARAMETER Lfs
Store the package .zip files with Git LFS.

.PARAMETER PackageTags
Also tag v<PackageVersion> when a package changed.

.PARAMETER Prune
Empty the repositories of packages that no longer exist on the tenant, as a
commit (only without -Package).

.PARAMETER NoCommit
Export only, leave the changes uncommitted.

.EXAMPLE
.\cpi-archive.ps1 -k $HOME\.cpi\dev-key.json -Login -p MyPackage -Lfs -Remote https://github.com/<you>/MyPackage.git -Push
#>
#Requires -Version 5.1
param(
  [Alias('k')][string]$ServiceKey,
  [string]$ApiUrl,
  [string]$TokenUrl,
  [string]$ClientId,
  [string]$ClientSecret,
  [switch]$Login,
  [int]$LoginPort = 8765,
  [Alias('d', 'Repo')][string]$Dir = '.',
  [Alias('p')][string[]]$Package = @(),
  [string]$GitName,
  [string]$GitEmail,
  [string[]]$Remote = @(),
  [switch]$Push,
  [switch]$Lfs,
  [switch]$PackageTags,
  [switch]$Prune,
  [switch]$NoCommit,
  [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar slows downloads down a lot

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }

function Write-Log([string]$Message) { [Console]::Error.WriteLine($Message) }
function Write-Warn([string]$Message) { [Console]::Error.WriteLine("WARN: $Message") }
function Stop-Archive([string]$Message) { throw $Message }

# entity set : folder in the archive
$script:Types = @(
  'IntegrationDesigntimeArtifacts:iflows'
  'ValueMappingDesigntimeArtifacts:valuemappings'
  'ScriptCollectionDesigntimeArtifacts:scripts'
  'MessageMappingDesigntimeArtifacts:mappings'
)
# Paths in a package repository that the script owns; everything else
# (.gitignore, ...) is left alone.
$script:Managed = @('package.json', 'README.md', '_export') + @($script:Types | ForEach-Object { ($_ -split ':')[1] })
# folder : heading in the generated README
$script:TypeTitles = @{
  iflows = 'Integration flows'; valuemappings = 'Value mappings'
  scripts = 'Script collections'; mappings = 'Message mappings'
}

$script:Utf8 = New-Object System.Text.UTF8Encoding $false
function Read-TextFile([string]$Path) { [IO.File]::ReadAllText($Path, $script:Utf8) }
function Write-TextFile([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $script:Utf8) }

function Remove-PathTree([string]$Path) {
  if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete($Path, $true) }
  elseif ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
}

# --- JSON -------------------------------------------------------------------
# ConvertFrom-Json turns date-like strings into DateTime and differs between
# PowerShell versions. This reader keeps every value as sent, and the writer
# produces the same text as "jq -S" in cpi-archive.sh (sorted keys, 2-space
# indent), so both scripts write identical files.
$script:ReWs  = [regex]'\G[ \t\r\n]*'
$script:ReStr = [regex]'\G"((?:[^"\\]|\\.)*)"'
$script:ReNum = [regex]'\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
$script:ReLit = [regex]'\G(?:true|false|null)'
$script:ReEsc = [regex]'\\(?:u([0-9a-fA-F]{4})|(.))'
$script:ReOut = [regex]'[\\"\x00-\x1f\x7f]'

function New-JsonObject { New-Object System.Collections.Specialized.OrderedDictionary }

function Skip-JsonWs { $script:JP += $script:ReWs.Match($script:JT, $script:JP).Length }

function Read-JsonString {
  $m = $script:ReStr.Match($script:JT, $script:JP)
  if (-not $m.Success) { throw "invalid JSON: expected a string at offset $($script:JP)" }
  $script:JP += $m.Length
  $raw = $m.Groups[1].Value
  if ($raw.IndexOf([char]'\') -lt 0) { return $raw }
  return $script:ReEsc.Replace($raw, {
      param($e)
      if ($e.Groups[1].Success) { return [string][char][Convert]::ToInt32($e.Groups[1].Value, 16) }
      switch -CaseSensitive ($e.Groups[2].Value) {
        'n' { "`n" } 't' { "`t" } 'r' { "`r" } 'b' { [string][char]8 } 'f' { [string][char]12 }
        default { $_ }
      }
    })
}

function Read-JsonValue {
  Skip-JsonWs
  if ($script:JP -ge $script:JT.Length) { throw 'invalid JSON: unexpected end' }
  $c = $script:JT[$script:JP]
  if ($c -eq [char]'{') {
    $obj = New-JsonObject
    $script:JP++
    Skip-JsonWs
    if ($script:JT[$script:JP] -eq [char]'}') { $script:JP++; return $obj }
    while ($true) {
      Skip-JsonWs
      $key = Read-JsonString
      Skip-JsonWs
      if ($script:JT[$script:JP] -ne [char]':') { throw "invalid JSON: expected ':' at offset $($script:JP)" }
      $script:JP++
      $obj[$key] = Read-JsonValue
      Skip-JsonWs
      $c = $script:JT[$script:JP]
      $script:JP++
      if ($c -eq [char]'}') { return $obj }
      if ($c -ne [char]',') { throw "invalid JSON: expected ',' or '}' at offset $($script:JP - 1)" }
    }
  }
  if ($c -eq [char]'[') {
    $list = New-Object System.Collections.Generic.List[object]
    $script:JP++
    Skip-JsonWs
    if ($script:JT[$script:JP] -eq [char]']') { $script:JP++; return , $list }
    while ($true) {
      $list.Add((Read-JsonValue))
      Skip-JsonWs
      $c = $script:JT[$script:JP]
      $script:JP++
      if ($c -eq [char]']') { return , $list }
      if ($c -ne [char]',') { throw "invalid JSON: expected ',' or ']' at offset $($script:JP - 1)" }
    }
  }
  if ($c -eq [char]'"') { return Read-JsonString }
  $m = $script:ReLit.Match($script:JT, $script:JP)
  if ($m.Success) {
    $script:JP += $m.Length
    switch ($m.Value) { 'true' { return $true } 'false' { return $false } default { return $null } }
  }
  $m = $script:ReNum.Match($script:JT, $script:JP)
  if ($m.Success -and $m.Length -gt 0) {
    $script:JP += $m.Length
    $inv = [Globalization.CultureInfo]::InvariantCulture
    try { return [decimal]::Parse($m.Value, [Globalization.NumberStyles]::Float, $inv) }
    catch { return [double]::Parse($m.Value, [Globalization.NumberStyles]::Float, $inv) }
  }
  throw "invalid JSON at offset $($script:JP)"
}

function ConvertFrom-JsonText([string]$Text) {
  $script:JT = $Text
  $script:JP = 0
  $value = Read-JsonValue
  Skip-JsonWs
  if ($script:JP -ne $script:JT.Length) { throw "invalid JSON: trailing data at offset $($script:JP)" }
  return , $value
}

function Format-JsonString([string]$Text) {
  $body = $script:ReOut.Replace($Text, {
      param($m)
      $code = [int][char]$m.Value
      switch ($code) {
        34 { '\"' } 92 { '\\' } 10 { '\n' } 9 { '\t' } 13 { '\r' } 8 { '\b' } 12 { '\f' }
        default { '\u{0:x4}' -f $code }
      }
    })
  return '"' + $body + '"'
}

function ConvertTo-JqText($Value, [string]$Indent = '') {
  if ($null -eq $Value) { return 'null' }
  if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
  if ($Value -is [string]) { return Format-JsonString $Value }
  $inv = [Globalization.CultureInfo]::InvariantCulture
  if ($Value -is [decimal]) { return $Value.ToString($inv) }
  if ($Value -is [double]) { return $Value.ToString('R', $inv) }
  $inner = "$Indent  "
  if ($Value -is [System.Collections.IDictionary]) {
    if ($Value.Count -eq 0) { return '{}' }
    $keys = [string[]]@($Value.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $parts = foreach ($k in $keys) { $inner + (Format-JsonString $k) + ': ' + (ConvertTo-JqText $Value[$k] $inner) }
    return "{`n" + ($parts -join ",`n") + "`n$Indent}"
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    # foreach, not @($Value): Windows PowerShell 5.1 fails on @() of some lists
    # ("Argument types do not match").
    $parts = foreach ($i in $Value) { $inner + (ConvertTo-JqText $i $inner) }
    if (-not $parts) { return '[]' }
    return "[`n" + ($parts -join ",`n") + "`n$Indent]"
  }
  return [string]$Value
}

function Write-JsonFile([string]$Path, $Value) { Write-TextFile $Path ((ConvertTo-JqText $Value) + "`n") }

# Drop OData noise and deferred navigation properties so metadata diffs stay clean.
function Get-CleanObject($Obj) {
  $clean = New-JsonObject
  foreach ($k in @($Obj.Keys)) {
    if ($k -ceq '__metadata' -or $k -ceq 'ArtifactContent') { continue }
    if ($Obj[$k] -is [System.Collections.IDictionary]) { continue }
    $clean[$k] = $Obj[$k]
  }
  return $clean
}

# --- authentication ---------------------------------------------------------
# POSTs the form fields to the token URL with the client as basic auth.
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
  if (-not $resp.access_token) { Stop-Archive 'no access_token in the token response' }
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

# OAuth authorization code flow: the user logs in in the browser and XSUAA
# redirects to http://localhost:PORT/callback with a one-time code, which a
# small listener on 127.0.0.1 receives.
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
  try { $listener.Start() } catch { Stop-Archive "cannot listen on port $LoginPort (in use? try -LoginPort)" }
  try {
    Write-Log 'Log in with your browser (waiting up to 5 minutes):'
    Write-Log "  $authUrl"
    try { Start-Process $authUrl } catch { }
    $deadline = (Get-Date).AddMinutes(5)
    $target = $null
    while (-not $target) {
      while (-not $listener.Pending()) {
        if ((Get-Date) -gt $deadline) { Stop-Archive "no login redirect received on $redirect within 5 minutes" }
        Start-Sleep -Milliseconds 200
      }
      $client = $listener.AcceptTcpClient()
      try {
        # Browsers also open idle connections; don't wait on them forever.
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
        $line = $reader.ReadLine()
        while ($reader.ReadLine()) { }
        $parts = "$line" -split ' '
        if ($parts.Count -ge 2 -and $parts[0] -eq 'GET' -and $parts[1].StartsWith('/callback?')) {
          $target = $parts[1]
          $status = '200 OK'
          $body = 'cpi-archive.ps1: login received, you can close this tab.'
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

  if ((Get-QueryParam $target 'state') -ne $state) { Stop-Archive 'login redirect has a wrong state, try again' }
  $code = Get-QueryParam $target 'code'
  if (-not $code) {
    Stop-Archive "login failed: $(Get-QueryParam $target 'error') $(Get-QueryParam $target 'error_description')"
  }
  if (-not (Request-Token @{ grant_type = 'authorization_code'; code = $code; redirect_uri = $redirect })) {
    Stop-Archive "token request to $($script:Cfg.CPI_TOKEN_URL) failed"
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
      Stop-Archive "token request to $($script:Cfg.CPI_TOKEN_URL) failed"
    }
  } elseif ($script:RefreshToken -and
    (Request-Token @{ grant_type = 'refresh_token'; refresh_token = $script:RefreshToken })) {
    return
  } else {
    Invoke-BrowserLogin
  }
}

# --- API --------------------------------------------------------------------
function Invoke-Get([string]$Url, [string]$OutFile, [string]$Accept = 'application/json') {
  try {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing `
      -Headers @{ Authorization = $script:AuthHeader; Accept = $Accept }
    return $true
  } catch {
    $resp = $_.Exception.Response
    if ($resp) { Write-Warn "HTTP $([int]$resp.StatusCode): $Url" }
    else { Write-Warn "request failed: $Url ($($_.Exception.Message))" }
    return $false
  }
}

# Path below the API -> list of result objects, follows paging. $null on failure.
function Get-ODataList([string]$Path) {
  $rows = New-Object System.Collections.Generic.List[object]
  $url = "$($script:Api)$Path"
  while ($url) {
    if (-not (Invoke-Get $url $script:PageFile)) { return $null }
    $doc = ConvertFrom-JsonText (Read-TextFile $script:PageFile)
    foreach ($r in $doc['d']['results']) { $rows.Add($r) }
    $next = [string]$doc['d']['__next']
    if (-not $next) { $url = $null }
    elseif ($next -like 'http*') { $url = $next }
    elseif ($next.StartsWith('/')) { $url = "$($script:Api)$next" }
    else { $url = "$($script:Api)/api/v1/$next" }
  }
  return , $rows
}

# Heuristic: iFlow properties whose key mentions "credential" or "alias"
# (credentialName, privateKeyAlias, ...). {{param}} values are resolved from
# the configuration. Returns "key<TAB>value" lines.
function Get-SecurityRefs([string]$ContentDir, $Params) {
  $files = @(Get-ChildItem -LiteralPath $ContentDir -Recurse -File -Filter '*.iflw')
  $text = (($files | ForEach-Object { Read-TextFile $_.FullName }) -join '') -replace "[`r`n]", ''
  $pattern = '<key>([^<]*(?i:credential|alias)[^<]*)</key>\s*<value>([^<]+)</value>'
  $lines = foreach ($m in [regex]::Matches($text, $pattern)) {
    $key = $m.Groups[1].Value.Trim("`t")
    $val = $m.Groups[2].Value.Trim("`t")
    if ($val -match '^\{\{(.+)\}\}$') {
      $name = $Matches[1]
      $hit = @($Params | Where-Object { $_['ParameterKey'] -ceq $name })
      if ($hit.Count) {
        $ref = $hit[0]['ParameterValue']
        if ($null -eq $ref) { $ref = 'null' }
        if ("$ref") { $val = "$ref" }
      }
    }
    if ($val) { "$key`t$val" }
  }
  if (-not $lines) { return , ([string[]]@()) }
  $unique = [string[]]@($lines | Select-Object -Unique)
  [Array]::Sort($unique, [StringComparer]::Ordinal)
  return , $unique
}

function Export-IflowExtras([string]$Id, [string]$ArtifactDir) {
  $url = "$($script:Api)/api/v1/IntegrationDesigntimeArtifacts(Id='$Id',Version='active')/Configurations"
  if (-not (Invoke-Get $url $script:CfgFile)) { return $false }
  $doc = ConvertFrom-JsonText (Read-TextFile $script:CfgFile)
  $params = New-Object System.Collections.Generic.List[object]
  foreach ($r in $doc['d']['results']) {
    $p = New-JsonObject
    foreach ($k in 'ParameterKey', 'ParameterValue', 'DataType') { $p[$k] = $r[$k] }
    $params.Add($p)
  }
  $params.Sort([Comparison[object]] {
      param($x, $y)
      [string]::CompareOrdinal([string]$x['ParameterKey'], [string]$y['ParameterKey'])
    })
  Write-JsonFile (Join-Path $ArtifactDir 'configuration.json') $params
  $refs = Get-SecurityRefs (Join-Path $ArtifactDir 'content') $params
  if ($refs.Count) {
    Write-TextFile (Join-Path $ArtifactDir 'security-refs.tsv') ((($refs | ForEach-Object { "$_`n" }) -join ''))
  }
  return $true
}

# --- README -----------------------------------------------------------------
# Markdown table cell: one line of plain text, without HTML tags and pipes.
function Format-MdCell($Value) {
  $text = [regex]::Replace([string]$Value, '<[^>]*>', ' ')
  $text = [regex]::Replace($text, '\s+', ' ').Trim()
  return $text.Replace('|', '\|')
}

# CPI dates are milliseconds since 1970 ("1713342313195" or "/Date(1713342313195)/").
function Format-CpiChange($Date, $By) {
  $text = ''
  $m = [regex]::Match([string]$Date, '\d{10,}')
  if ($m.Success) {
    $text = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$m.Value).UtcDateTime.ToString(
      'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  }
  $who = Format-MdCell $By
  if ($text -and $who) { return "$text by $who" }
  return "$text$who"
}

# README.md from the package and artifact metadata, so the repository page
# shows what the package holds. It uses no run time or date, so an unchanged
# package gets the same README and no commit.
# $Artifacts: list of @{ Folder = 'iflows'; Row = <artifact metadata> }.
function Write-PackageReadme([string]$Out, $Pkg, $Artifacts) {
  $id = [string]$Pkg['Id']
  $title = Format-MdCell $Pkg['Name']
  if (-not $title) { $title = $id }
  $md = New-Object System.Collections.Generic.List[string]
  $md.Add("# $title")
  foreach ($text in (Format-MdCell $Pkg['ShortText']), (Format-MdCell $Pkg['Description'])) {
    if ($text -and -not $md.Contains($text)) { $md.Add(''); $md.Add($text) }
  }
  $md.Add('')
  $md.Add('| | |')
  $md.Add('|---|---|')
  $facts = @(
    @('Package ID', "``$id``"), @('Tenant', "``$($script:TenantHost)``"),
    @('Version', (Format-MdCell $Pkg['Version'])), @('Vendor', (Format-MdCell $Pkg['Vendor'])),
    @('Mode', (Format-MdCell $Pkg['Mode'])),
    @('Created', (Format-CpiChange $Pkg['CreationDate'] $Pkg['CreatedBy'])),
    @('Last modified', (Format-CpiChange $Pkg['ModifiedDate'] $Pkg['ModifiedBy']))
  )
  foreach ($f in $facts) { if ($f[1]) { $md.Add("| $($f[0]) | $($f[1]) |") } }
  $md.Add('')
  $md.Add('Archived from SAP Cloud Integration by cpi-archive. Every change in CPI is one commit with a ' +
    '`snapshot/YYYYMMDD-HHMMSS` tag. The script writes this file on every run, so edits to it are overwritten.')

  foreach ($entry in $script:Types) {
    $folder = ($entry -split ':')[1]
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($a in $Artifacts) { if ($a.Folder -ceq $folder) { $rows.Add($a.Row) } }
    if (-not $rows.Count) { continue }
    $rows.Sort([Comparison[object]] { param($x, $y) [string]::CompareOrdinal([string]$x['Id'], [string]$y['Id']) })
    $dated = $false
    foreach ($r in $rows) { if ($r['ModifiedAt']) { $dated = $true } }
    $md.Add('')
    $md.Add("## $($script:TypeTitles[$folder]) ($($rows.Count))")
    $md.Add('')
    if ($dated) { $md.Add('| Name | Version | Last modified | Description |'); $md.Add('|---|---|---|---|') }
    else { $md.Add('| Name | Version | Description |'); $md.Add('|---|---|---|') }
    foreach ($r in $rows) {
      $rid = [string]$r['Id']
      $name = Format-MdCell $r['Name']
      if (-not $name) { $name = $rid }
      $cell = "[$name]($folder/$rid/)"
      if ($name -cne $rid) { $cell += " (ID ``$rid``)" }
      $cells = @($cell, (Format-MdCell $r['Version']))
      if ($dated) { $cells += Format-CpiChange $r['ModifiedAt'] $r['ModifiedBy'] }
      $cells += Format-MdCell $r['Description']
      $md.Add('| ' + ($cells -join ' | ') + ' |')
    }
  }
  if (-not $Artifacts.Count) { $md.Add(''); $md.Add('The package has no design-time artifacts.') }

  $md.Add('')
  $md.Add('## Restoring')
  $md.Add('')
  if (Test-Path -LiteralPath (Join-Path (Join-Path $Out '_export') "$id.zip")) {
    $md.Add("1. Take the package export from the snapshot you need (with Git LFS, run ``git lfs pull`` first):")
    $md.Add("   ``git show snapshot/<YYYYMMDD-HHMMSS>:_export/$id.zip > $id.zip``")
    $md.Add('2. In CPI, open **Design**, choose **Import** and select the zip.')
  } else {
    $md.Add('1. CPI gave no full export of this package. Zip an artifact''s `content/` folder from the snapshot ' +
      'you need, keeping its folder structure.')
    $md.Add('2. In CPI, upload it as a single artifact into the package.')
  }
  $md.Add('3. Set the externalized parameters from each iFlow''s `configuration.json` of the same snapshot.')
  $md.Add('4. Create the security material the iFlows use on the tenant, then deploy.')
  Write-TextFile (Join-Path $Out 'README.md') (($md -join "`n") + "`n")
}

# --- git --------------------------------------------------------------------
# Runs git and returns its output; the exit code is in $script:GitExit.
# Windows PowerShell turns redirected stderr of native commands into errors,
# hence the local ErrorActionPreference.
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

# Refuses folders that would lose or mix up content: non-git folders with files
# and repositories with uncommitted changes.
function Test-PackageRepo([string]$RepoDir) {
  if (Test-Path -LiteralPath (Join-Path $RepoDir '.git')) {
    $status = Invoke-Git @('-C', $RepoDir, 'status', '--porcelain')
    if ($script:GitExit -or $status) {
      Write-Warn "$RepoDir has uncommitted changes; commit or discard them first"
      return $false
    }
  } elseif ((Test-Path -LiteralPath $RepoDir) -and
    (Get-ChildItem -LiteralPath $RepoDir -Force | Select-Object -First 1)) {
    Write-Warn "$RepoDir is not empty and not a git repository"
    return $false
  }
  return $true
}

function Initialize-PackageRepo([string]$RepoDir, [string]$PackageId) {
  if (-not (Test-Path -LiteralPath (Join-Path $RepoDir '.git'))) {
    Write-Log "  creating repository $RepoDir"
    [void][IO.Directory]::CreateDirectory($RepoDir)
    Invoke-GitOrThrow @('-C', $RepoDir, 'init', '-q', '-b', 'main')
    # Store files byte for byte: no line-ending conversion of scripts or XML.
    Write-TextFile (Join-Path $RepoDir '.gitattributes') "* -text`n"
  }
  # iFlow content paths get long; let git on Windows go beyond 260 characters.
  Invoke-GitOrThrow @('-C', $RepoDir, 'config', 'core.longpaths', 'true')
  if ($Lfs) {
    Invoke-GitOrThrow @('-C', $RepoDir, 'lfs', 'install', '--local')
    Invoke-GitOrThrow @('-C', $RepoDir, 'lfs', 'track', '_export/*.zip')
  }
  if (-not $script:Remotes.ContainsKey($PackageId)) { return }
  $url = $script:Remotes[$PackageId]
  $current = [string](Invoke-Git -Quiet @('-C', $RepoDir, 'remote', 'get-url', 'origin'))
  if ($script:GitExit -or -not $current) {
    Invoke-GitOrThrow @('-C', $RepoDir, 'remote', 'add', 'origin', $url)
    Write-Log "  origin set to $url"
  } elseif ($current -cne $url) {
    Invoke-GitOrThrow @('-C', $RepoDir, 'remote', 'set-url', 'origin', $url)
    Write-Log "  origin changed from $current to $url"
  }
}

# Builds the package in a staging folder and only replaces the archived copy
# when everything downloaded, so a failed run never deletes archived content.
function Export-CpiPackage([string]$PackageId, [string]$RepoDir) {
  $out = Join-Path $script:Tmp 'pkg'
  Remove-PathTree $out
  [void][IO.Directory]::CreateDirectory((Join-Path $out '_export'))
  $pkgUrl = "$($script:Api)/api/v1/IntegrationPackages('$PackageId')"

  if (-not (Invoke-Get $pkgUrl $script:PkgFile)) { return $false }
  $doc = ConvertFrom-JsonText (Read-TextFile $script:PkgFile)
  $pkg = Get-CleanObject $doc['d']
  Write-JsonFile (Join-Path $out 'package.json') $pkg
  $artifacts = New-Object System.Collections.Generic.List[object]

  $zip = Join-Path (Join-Path $out '_export') "$PackageId.zip"
  if (-not (Invoke-Get "$pkgUrl/`$value" $zip '*/*')) {
    Write-Warn "  no full export for $PackageId (configure-only SAP content?), continuing without the .zip"
    Remove-PathTree $zip
  }

  foreach ($entry in $script:Types) {
    $entity, $folder = $entry -split ':'
    $rows = Get-ODataList "/api/v1/IntegrationPackages('$PackageId')/$entity"
    if ($null -eq $rows) { return $false }
    foreach ($row in $rows) {
      $id = [string]$row['Id']
      $artifactDir = Join-Path (Join-Path $out $folder) $id
      $contentDir = Join-Path $artifactDir 'content'
      [void][IO.Directory]::CreateDirectory($contentDir)
      $clean = Get-CleanObject $row
      Write-JsonFile (Join-Path $artifactDir 'artifact.json') $clean
      $artifacts.Add(@{ Folder = $folder; Row = $clean })
      Write-Log "  $folder/$id"
      $url = "$($script:Api)/api/v1/$entity(Id='$id',Version='active')/`$value"
      if (-not (Invoke-Get $url $script:ArtifactZip '*/*')) { return $false }
      [IO.Compression.ZipFile]::ExtractToDirectory($script:ArtifactZip, $contentDir)
      if ($entity -eq 'IntegrationDesigntimeArtifacts') {
        if (-not (Export-IflowExtras $id $artifactDir)) { return $false }
      }
    }
  }
  Write-PackageReadme $out $pkg $artifacts

  Initialize-PackageRepo $RepoDir $PackageId
  foreach ($path in $script:Managed) { Remove-PathTree (Join-Path $RepoDir $path) }
  foreach ($item in @(Get-ChildItem -LiteralPath $out -Force)) {
    Move-Item -LiteralPath $item.FullName -Destination (Join-Path $RepoDir $item.Name)
  }
  return $true
}

# The export .zip differs on every download (timestamps). If nothing else in the
# package changed, keep the committed .zip so unchanged packages create no commit.
function Restore-UnchangedZip([string]$RepoDir, [string]$PackageId) {
  $zip = "_export/$PackageId.zip"
  Invoke-Git -Quiet @('-C', $RepoDir, 'rev-parse', '-q', '--verify', "HEAD:$zip") | Out-Null
  if ($script:GitExit) { return }
  $status = Invoke-Git @('-C', $RepoDir, 'status', '--porcelain', '--', '.', ':(exclude)_export')
  if ($status) { return }
  Invoke-GitOrThrow @('-C', $RepoDir, 'checkout', '-q', 'HEAD', '--', $zip)
}

function Save-PackageCommit([string]$RepoDir, [string]$PackageId, [string]$Subject) {
  if (-not $Subject) { $Subject = "Snapshot of $PackageId from $($script:TenantHost) at $($script:Stamp)" }
  Invoke-GitOrThrow @('-C', $RepoDir, 'add', '-A')
  Invoke-Git -Quiet @('-C', $RepoDir, 'diff', '--cached', '--quiet') | Out-Null
  if ($script:GitExit -eq 0) {
    Write-Log '  no changes since the last snapshot'
    return
  }
  $names = Invoke-Git @('-C', $RepoDir, 'diff', '--cached', '--name-only')
  $changed = [string[]]@($names | ForEach-Object {
      $s = $_ -split '/'
      if ($s.Count -gt 2 -and $s[0] -cne '_export') { "$($s[0])/$($s[1])" }
    } | Select-Object -Unique)
  [Array]::Sort($changed, [StringComparer]::Ordinal)
  $msg = "$Subject`n"
  if ($changed.Count) { $msg += "`nChanged artifacts:`n" + (($changed | ForEach-Object { "- $_`n" }) -join '') }
  Write-TextFile $script:MsgFile $msg
  Invoke-GitOrThrow ($script:GitId + @('-C', $RepoDir, 'commit', '-q', '-F', $script:MsgFile))
  Invoke-GitOrThrow ($script:GitId + @('-C', $RepoDir, 'tag', '-a', $script:RunTag, '-m',
      "$PackageId from $($script:TenantHost) at $($script:Stamp)"))
  Write-Log "  committed and tagged $($script:RunTag)"

  $pkgFile = Join-Path $RepoDir 'package.json'
  if (-not $PackageTags -or -not (Test-Path -LiteralPath $pkgFile)) { return }
  $ver = [string](ConvertFrom-JsonText (Read-TextFile $pkgFile))['Version']
  if (-not $ver) { return }
  $tag = "v$ver"
  Invoke-Git -Quiet @('check-ref-format', "tags/$tag") | Out-Null
  if ($script:GitExit) { Write-Warn "  cannot use $tag as a tag name"; return }
  Invoke-Git -Quiet @('-C', $RepoDir, 'rev-parse', '-q', '--verify', "refs/tags/$tag") | Out-Null
  if ($script:GitExit -eq 0) {
    Write-Warn "  $PackageId changed but its version $ver is already tagged (version not raised in CPI?)"
    return
  }
  Invoke-GitOrThrow ($script:GitId + @('-C', $RepoDir, 'tag', '-a', $tag, '-m', "$PackageId $ver, snapshot $($script:Stamp)"))
  Write-Log "  tagged $tag"
}

# Pushes on every run, not only after a new commit, so a push that failed
# earlier (remote repository not created yet, network) is caught up later.
function Push-PackageRepo([string]$RepoDir) {
  Invoke-Git -Quiet @('-C', $RepoDir, 'rev-parse', '-q', '--verify', 'HEAD') | Out-Null
  if ($script:GitExit) { return }
  Invoke-Git -Quiet @('-C', $RepoDir, 'remote', 'get-url', 'origin') | Out-Null
  if ($script:GitExit) { throw 'no origin to push to (use -Remote PACKAGE=URL)' }
  Invoke-Git @('-C', $RepoDir, 'push', '-q', '-u', '--follow-tags', 'origin', 'HEAD') | Out-Null
  if ($script:GitExit) { throw 'push to origin failed' }
  Write-Log '  pushed'
}

# --- main -------------------------------------------------------------------
$exitCode = 0
$script:Tmp = $null
try {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Stop-Archive 'git is not installed (install Git for Windows)' }
  if ($Lfs) {
    Invoke-Git -Quiet @('lfs', 'version') | Out-Null
    if ($script:GitExit) { Stop-Archive 'git-lfs is not installed' }
  }
  if ($Prune -and $Package.Count) { Stop-Archive '-Prune only works when archiving all packages' }
  foreach ($assembly in 'System.IO.Compression.FileSystem', 'System.IO.Compression.ZipFile') {
    try { Add-Type -AssemblyName $assembly } catch { }
  }
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  }

  # Package id -> origin URL, from -Remote PKG=URL (or -Remote URL with one -Package).
  $script:Remotes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
  foreach ($arg in $Remote) {
    if ($arg -match '^([A-Za-z0-9_.-]+)=(.+)$') { $script:Remotes[$Matches[1]] = $Matches[2] }
    elseif ($Package.Count -eq 1) { $script:Remotes[$Package[0]] = $arg }
    else { Stop-Archive "-Remote ${arg}: use -Remote PACKAGE=URL (plain -Remote URL needs exactly one -Package)" }
  }
  if ($Package.Count) {
    foreach ($id in $script:Remotes.Keys) {
      if ($Package -cnotcontains $id) { Stop-Archive "-Remote for $id, but $id is not among the -Package packages" }
    }
  }

  # Connection: environment, then service key, then options.
  $script:Cfg = @{}
  foreach ($name in 'CPI_API_URL', 'CPI_TOKEN_URL', 'CPI_CLIENT_ID', 'CPI_CLIENT_SECRET', 'CPI_USER', 'CPI_PASSWORD', 'CPI_AUTH_URL') {
    $script:Cfg[$name] = [Environment]::GetEnvironmentVariable($name)
  }
  if ($ServiceKey) {
    $key = ConvertFrom-JsonText (Read-TextFile (Resolve-Path -LiteralPath $ServiceKey).ProviderPath)
    $oauth = $key['oauth']
    if ($oauth -isnot [System.Collections.IDictionary]) { $oauth = New-JsonObject }
    $script:Cfg.CPI_API_URL = [string]$oauth['url']
    $script:Cfg.CPI_TOKEN_URL = [string]$oauth['tokenurl']
    $script:Cfg.CPI_CLIENT_ID = [string]$oauth['clientid']
    $script:Cfg.CPI_CLIENT_SECRET = [string]$oauth['clientsecret']
    $script:Cfg.CPI_AUTH_URL = [string]$oauth['authorizationurl']
  }
  if ($ApiUrl) { $script:Cfg.CPI_API_URL = $ApiUrl }
  if ($TokenUrl) { $script:Cfg.CPI_TOKEN_URL = $TokenUrl }
  if ($ClientId) { $script:Cfg.CPI_CLIENT_ID = $ClientId }
  if ($ClientSecret) { $script:Cfg.CPI_CLIENT_SECRET = $ClientSecret }

  if ($Login) { $script:AuthMode = 'login' }
  elseif ($script:Cfg.CPI_USER) { $script:AuthMode = 'basic' }
  else { $script:AuthMode = 'client' }
  if (-not $script:Cfg.CPI_API_URL) { Stop-Archive 'set CPI_API_URL, -ApiUrl or -ServiceKey' }
  if ($script:AuthMode -eq 'basic') {
    if (-not $script:Cfg.CPI_PASSWORD) { Stop-Archive 'set CPI_PASSWORD' }
  } else {
    if (-not $script:Cfg.CPI_TOKEN_URL) { Stop-Archive 'set CPI_TOKEN_URL or -TokenUrl (or CPI_USER/CPI_PASSWORD)' }
    if (-not $script:Cfg.CPI_CLIENT_ID) { Stop-Archive 'set CPI_CLIENT_ID or -ClientId' }
    if (-not $script:Cfg.CPI_CLIENT_SECRET) { Stop-Archive 'set CPI_CLIENT_SECRET or -ClientSecret' }
  }
  $script:Api = $script:Cfg.CPI_API_URL.TrimEnd('/')
  $script:TenantHost = ([regex]::Match($script:Api, '^[^:]+://([^/]+)')).Groups[1].Value
  $now = (Get-Date).ToUniversalTime()
  $script:Stamp = $now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
  $script:RunTag = 'snapshot/' + $now.ToString('yyyyMMdd-HHmmss')
  $script:AuthHeader = $null
  $script:TokenExp = 0
  $script:RefreshToken = $null

  # --- checks ---------------------------------------------------------------
  $rootPath = $Dir -replace '^~', $HOME
  $root = [IO.Path]::GetFullPath([IO.Path]::Combine($PWD.ProviderPath, $rootPath))
  [void][IO.Directory]::CreateDirectory($root)
  if (Test-Path -LiteralPath (Join-Path $root '.git')) {
    Stop-Archive "$root is a git repository itself; use a plain folder (each package gets its own repository inside)"
  }
  # Resolve the commit identity now, so a missing one fails before the export.
  $name = $GitName
  if (-not $name) { $name = $env:CPI_GIT_NAME }
  if (-not $name) { $name = [string](Invoke-Git -Quiet @('-C', $root, 'config', 'user.name')) }
  $email = $GitEmail
  if (-not $email) { $email = $env:CPI_GIT_EMAIL }
  if (-not $email) { $email = [string](Invoke-Git -Quiet @('-C', $root, 'config', 'user.email')) }
  if (-not $NoCommit -and (-not $name -or -not $email)) {
    Stop-Archive "no git identity: use -GitName/-GitEmail or set git's user.name/user.email"
  }
  $script:GitId = @('-c', "user.name=$name", '-c', "user.email=$email")

  # Staging lives next to the repositories, so moving it in never crosses drives.
  $script:Tmp = Join-Path $root ('.cpi-archive-tmp-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  [void][IO.Directory]::CreateDirectory($script:Tmp)
  $script:PageFile = Join-Path $script:Tmp 'page.json'
  $script:PkgFile = Join-Path $script:Tmp 'pkg.json'
  $script:CfgFile = Join-Path $script:Tmp 'cfg.json'
  $script:ArtifactZip = Join-Path $script:Tmp 'artifact.zip'
  $script:MsgFile = Join-Path $script:Tmp 'commit-msg'

  # --- export, commit, push -------------------------------------------------
  Update-Token
  if ($Package.Count -eq 0) {
    $rows = Get-ODataList '/api/v1/IntegrationPackages'
    if ($null -eq $rows) { Stop-Archive 'cannot list packages' }
    $packages = @($rows | ForEach-Object { [string]$_['Id'] })
  } else {
    $packages = @($Package)
  }
  Write-Log "Archiving $($packages.Count) package(s) from $($script:TenantHost) into $root"

  $failed = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($packageId in $packages) {
    [void]$seen.Add($packageId)
    Update-Token
    Write-Log "Package $packageId"
    $repoDir = Join-Path $root $packageId
    $ok = $false
    try {
      if ($packageId -cnotmatch '^[A-Za-z0-9_.-]+$') {
        Write-Warn "package id $packageId cannot be used as a folder name"
      } elseif ((Test-PackageRepo $repoDir) -and (Export-CpiPackage $packageId $repoDir)) {
        Restore-UnchangedZip $repoDir $packageId
        if (-not $NoCommit) {
          Save-PackageCommit $repoDir $packageId
          if ($Push) { Push-PackageRepo $repoDir }
        }
        $ok = $true
      } else {
        Write-Warn "package $packageId failed; its repository was left unchanged"
      }
    } catch {
      Write-Warn "package ${packageId}: $($_.Exception.Message)"
    }
    if (-not $ok) { $failed.Add($packageId) }
  }

  if ($Prune) {
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force)) {
      $packageId = $d.Name
      $repoDir = $d.FullName
      if (-not (Test-Path -LiteralPath (Join-Path $repoDir '.git')) -or
        -not (Test-Path -LiteralPath (Join-Path $repoDir 'package.json')) -or
        $seen.Contains($packageId)) { continue }
      Write-Log "Package $packageId no longer exists on the tenant, emptying its repository"
      try {
        if (-not (Test-PackageRepo $repoDir)) { throw 'repository left unchanged' }
        foreach ($path in $script:Managed) { Remove-PathTree (Join-Path $repoDir $path) }
        if (-not $NoCommit) {
          Save-PackageCommit $repoDir $packageId "Package $packageId deleted on $($script:TenantHost) (seen at $($script:Stamp))"
          if ($Push) { Push-PackageRepo $repoDir }
        }
      } catch {
        Write-Warn "package ${packageId}: $($_.Exception.Message)"
        $failed.Add($packageId)
      }
    }
  }

  if ($NoCommit) { Write-Log 'Export done, changes left uncommitted in the package repositories' }
  if ($failed.Count) {
    Write-Warn "failed: $($failed -join ' ')"
    $exitCode = 1
  }
} catch {
  [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
  $exitCode = 1
} finally {
  if ($script:Tmp) {
    try { Remove-PathTree $script:Tmp } catch { Write-Warn "could not remove $($script:Tmp)" }
  }
}
exit $exitCode
