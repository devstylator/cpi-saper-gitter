#!/usr/bin/env bash
# cpi-local-archive.sh: download SAP Cloud Integration packages into a local
# folder, one sub-folder per package (<dir>/<PackageId>/). No git involved.
#
# Derived from cpi-archive.sh. Per package it stores the package metadata, a
# README.md made from it, the full package export (.zip), every design-time
# artifact (iFlows, value mappings, script collections, message mappings)
# unzipped, and for iFlows the configured externalized parameters plus the
# names of referenced security material.
#
# --check runs a test instead: it writes nothing, tries the full export of each
# package and reports the packages CPI refuses to export (typically because an
# artifact is still in draft state), with the reason CPI gives.
#
# Requires: bash 4+, curl 7.55+, jq, unzip, GNU grep (python3 for the
# automatic browser callback of --login).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cpi-local-archive.sh -d DIR [options]
       cpi-local-archive.sh --check [options]

Connection (options, --service-key or environment variables; options win):
  CPI_API_URL        API base URL, e.g. https://<tenant>.it-cpi0xx.cfapps.<region>.hana.ondemand.com
  CPI_TOKEN_URL      OAuth token URL          \
  CPI_CLIENT_ID      OAuth client id           > OAuth client (Cloud Foundry)
  CPI_CLIENT_SECRET  OAuth client secret      /
  CPI_USER / CPI_PASSWORD   basic auth instead of OAuth

Connection options:
  -k, --service-key FILE  read URL and OAuth data from a BTP service key (JSON, plan "api")
      --api-url URL       API base URL (CPI_API_URL)
      --token-url URL     OAuth token URL (CPI_TOKEN_URL)
      --client-id ID      OAuth client id (CPI_CLIENT_ID)
      --client-secret S   OAuth client secret (CPI_CLIENT_SECRET); visible in the
                          process list, prefer the variable or the service key
      --login             log in as a user in the browser (OAuth authorization code)
                          instead of using client credentials
      --login-port PORT   local port for the login redirect (default: 8765), the
                          client must allow http://localhost:PORT/callback

Options:
  -d, --dir DIR           target folder (required unless --check); each package
                          goes to DIR/<PackageId>/, replacing an earlier download
      --dated             put this run into DIR/<YYYYMMDD-HHMMSS>/ instead, so
                          earlier runs are kept side by side
  -p, --package ID        package to process; repeatable (default: all packages)
  -x, --exclude ID        skip this package; repeatable
      --strict            treat a package without a full export (.zip) as failed
                          and do not write it (default: warn, keep the artifacts)
  -c, --check             test mode: write nothing, try the full export of every
                          package and list those that cannot be exported, with
                          CPI's reason and the artifacts that look like drafts.
                          Exit code 2 if any package cannot be exported
  -h, --help              show this help
EOF
}

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# entity set : folder in the archive
TYPES=(
  "IntegrationDesigntimeArtifacts:iflows"
  "ValueMappingDesigntimeArtifacts:valuemappings"
  "ScriptCollectionDesigntimeArtifacts:scripts"
  "MessageMappingDesigntimeArtifacts:mappings"
)
# Drop OData noise and deferred navigation properties.
CLEAN='del(.__metadata, .ArtifactContent) | with_entries(select(.value | type != "object"))'

ROOT="" PACKAGES=() EXCLUDES=() SERVICE_KEY=""
CHECK=0 DATED=0 STRICT=0 LOGIN=0 LOGIN_PORT=8765
declare -A OPT=()   # connection values given as options
while (($#)); do
  case $1 in
    -k|--service-key) SERVICE_KEY=${2:?"$1 needs a value"}; shift 2 ;;
    --api-url)        OPT[CPI_API_URL]=${2:?"$1 needs a value"}; shift 2 ;;
    --token-url)      OPT[CPI_TOKEN_URL]=${2:?"$1 needs a value"}; shift 2 ;;
    --client-id)      OPT[CPI_CLIENT_ID]=${2:?"$1 needs a value"}; shift 2 ;;
    --client-secret)  OPT[CPI_CLIENT_SECRET]=${2:?"$1 needs a value"}; shift 2 ;;
    --login)          LOGIN=1; shift ;;
    --login-port)     LOGIN_PORT=${2:?"$1 needs a value"}; shift 2 ;;
    -d|--dir)         ROOT=${2:?"$1 needs a value"}; shift 2 ;;
    --dated)          DATED=1; shift ;;
    -p|--package)     PACKAGES+=("${2:?"$1 needs a value"}"); shift 2 ;;
    -x|--exclude)     EXCLUDES+=("${2:?"$1 needs a value"}"); shift 2 ;;
    --strict)         STRICT=1; shift ;;
    -c|--check)       CHECK=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; die "unknown option: $1" ;;
  esac
done

for cmd in curl jq unzip; do
  command -v "$cmd" >/dev/null || die "$cmd is not installed"
done
if ((CHECK == 0)) && [[ -z $ROOT ]]; then
  usage >&2; die "give the target folder with -d DIR (or use --check)"
fi

if [[ -n $SERVICE_KEY ]]; then
  CPI_API_URL=$(jq -r '.oauth.url // empty' "$SERVICE_KEY")
  CPI_TOKEN_URL=$(jq -r '.oauth.tokenurl // empty' "$SERVICE_KEY")
  CPI_CLIENT_ID=$(jq -r '.oauth.clientid // empty' "$SERVICE_KEY")
  CPI_CLIENT_SECRET=$(jq -r '.oauth.clientsecret // empty' "$SERVICE_KEY")
  CPI_AUTH_URL=$(jq -r '.oauth.authorizationurl // empty' "$SERVICE_KEY")
fi
for var in "${!OPT[@]}"; do
  printf -v "$var" '%s' "${OPT[$var]}"
done
[[ $LOGIN_PORT =~ ^[0-9]+$ ]] || die "--login-port needs a number"
if ((LOGIN)); then
  AUTH=login
elif [[ -n ${CPI_USER:-} ]]; then
  AUTH=basic
else
  AUTH=client
fi
: "${CPI_API_URL:?set CPI_API_URL, --api-url or --service-key}"
if [[ $AUTH == basic ]]; then
  : "${CPI_PASSWORD:?set CPI_PASSWORD}"
else
  : "${CPI_TOKEN_URL:?set CPI_TOKEN_URL or --token-url (or CPI_USER/CPI_PASSWORD)}"
  : "${CPI_CLIENT_ID:?set CPI_CLIENT_ID or --client-id}"
  : "${CPI_CLIENT_SECRET:?set CPI_CLIENT_SECRET or --client-secret}"
fi
API=${CPI_API_URL%/}
HOST=${API#*://}; HOST=${HOST%%/*}
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_DIR=$(date -u +%Y%m%d-%H%M%S)

umask 077
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
AUTH_HDR="$TMP/auth-header"   # credentials stay out of the process list
TOKEN_EXP=0 REFRESH_TOKEN=""

# POSTs the form fields (name=value ...) to the token URL. Client credentials
# and form data go through curl's stdin config, so they stay out of the process list.
token_request() {
  local resp token field
  resp=$({
      printf 'user = "%s:%s"\n' "$CPI_CLIENT_ID" "$CPI_CLIENT_SECRET"
      for field; do printf 'data-urlencode = "%s"\n' "$field"; done
    } | curl -sS -f -K - "$CPI_TOKEN_URL") || return 1
  token=$(jq -r '.access_token // empty' <<<"$resp")
  [[ -n $token ]] || die "no access_token in the token response"
  TOKEN_EXP=$(( $(date +%s) + $(jq -r '.expires_in // 3600' <<<"$resp") ))
  REFRESH_TOKEN=$(jq -r --arg old "$REFRESH_TOKEN" '.refresh_token // $old' <<<"$resp")
  printf 'Authorization: Bearer %s\n' "$token" > "$AUTH_HDR"
}

query_param() { # url name -> percent-decoded value of that query parameter
  local v
  v=$(sed -nE "s/.*[?&]$2=([^&#]*).*/\1/p" <<<"$1")
  v=${v//+/ }
  printf '%b' "${v//%/\\x}"
}

# One-shot HTTP server for the login redirect: creates the ready file once it
# listens, prints the callback path and exits.
LISTENER=$(cat <<'EOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if not self.path.startswith("/callback?"):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"cpi-local-archive.sh: login received, you can close this tab.\n")
        print(self.path, flush=True)
        self.server.done = True
    def log_message(self, *args):
        pass
srv = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
open(sys.argv[2], "w").close()
srv.done = False
while not srv.done:
    srv.handle_request()
EOF
)

# OAuth authorization code flow: the user logs in in the browser and XSUAA
# redirects to http://localhost:PORT/callback with a one-time code.
browser_login() {
  local redirect="http://localhost:$LOGIN_PORT/callback" state auth_url url code pid
  state=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  auth_url="${CPI_AUTH_URL:-${CPI_TOKEN_URL%/oauth/token}/oauth/authorize}?response_type=code"
  auth_url+="&client_id=$(jq -rn --arg v "$CPI_CLIENT_ID" '$v | @uri')"
  auth_url+="&redirect_uri=$(jq -rn --arg v "$redirect" '$v | @uri')&state=$state"

  if command -v python3 >/dev/null; then
    timeout 300 python3 -c "$LISTENER" "$LOGIN_PORT" "$TMP/listening" > "$TMP/callback" 2>/dev/null &
    pid=$!
    while [[ ! -e $TMP/listening ]] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
    [[ -e $TMP/listening ]] || die "cannot listen on port $LOGIN_PORT (in use? try --login-port)"
    log "Log in with your browser (waiting up to 5 minutes):"
    log "  $auth_url"
    { xdg-open "$auth_url" || open "$auth_url"; } >/dev/null 2>&1 || true
    wait "$pid" || die "no login redirect received on $redirect within 5 minutes"
    url=$(<"$TMP/callback")
  else
    log "Open this address and log in:"
    log "  $auth_url"
    log "The browser then fails to load $redirect. Paste that full address here:"
    read -r url </dev/tty
  fi

  [[ $(query_param "$url" state) == "$state" ]] || die "login redirect has a wrong state, try again"
  code=$(query_param "$url" code)
  [[ -n $code ]] || die "login failed: $(query_param "$url" error) $(query_param "$url" error_description)"
  token_request grant_type=authorization_code "code=$code" "redirect_uri=$redirect" \
    || die "token request to $CPI_TOKEN_URL failed"
  log "Logged in"
}

ensure_token() {
  if [[ $AUTH == basic ]]; then
    [[ -s $AUTH_HDR ]] || printf 'Authorization: Basic %s\n' \
      "$(printf '%s:%s' "$CPI_USER" "$CPI_PASSWORD" | base64 | tr -d '\n')" > "$AUTH_HDR"
    return 0
  fi
  (( $(date +%s) < TOKEN_EXP - 300 )) && return 0
  if [[ $AUTH == client ]]; then
    token_request grant_type=client_credentials || die "token request to $CPI_TOKEN_URL failed"
  elif [[ -n $REFRESH_TOKEN ]] \
    && token_request grant_type=refresh_token "refresh_token=$REFRESH_TOKEN"; then
    :
  else
    browser_login
  fi
}

HTTP_CODE=""
http_get() { # url outfile [accept] [quiet] -> sets HTTP_CODE; on error the body stays in outfile
  HTTP_CODE=$(curl -sS -g -H @"$AUTH_HDR" -H "Accept: ${3:-application/json}" \
    -o "$2" -w '%{http_code}' "$1") || { HTTP_CODE=000; warn "request failed: $1"; return 1; }
  [[ $HTTP_CODE == 2?? ]] && return 0
  [[ -n ${4:-} ]] || warn "HTTP $HTTP_CODE: $1"
  return 1
}

# One line of text from an error response (OData JSON, XML or HTML).
error_text() { # file
  local msg=""
  [[ -s $1 ]] || return 0
  msg=$(jq -r '[.error.message.value?, .error.message?, .message?, .error?] | map(strings) | first // empty' \
    "$1" 2>/dev/null) || msg=""
  if [[ -z $msg ]]; then
    msg=$(head -c 4000 "$1" | tr -d '\r\0' | sed -E 's/<[^>]*>/ /g' | tr -s ' \n\t' ' ') || true
  fi
  msg=${msg# }
  printf '%s' "${msg:0:400}"
}

odata_list() { # path below API -> one compact JSON object per line, follows paging
  local url="$API$1" next
  while [[ -n $url ]]; do
    http_get "$url" "$TMP/page.json" || return 1
    jq -c '.d.results[]' "$TMP/page.json"
    next=$(jq -r '.d.__next // empty' "$TMP/page.json")
    case $next in
      "")     url="" ;;
      http*)  url=$next ;;
      /*)     url="$API$next" ;;
      *)      url="$API/api/v1/$next" ;;
    esac
  done
}

# Heuristic: iFlow properties whose key mentions "credential" or "alias"
# (credentialName, privateKeyAlias, ...). {{param}} values are resolved from
# the configuration. Prints "key<TAB>value" lines.
security_refs() { # content_dir configuration.json
  local cfg=$2 key val ref
  find "$1" -name '*.iflw' -exec cat {} + 2>/dev/null | tr -d '\r\n' \
    | { grep -oP '<key>[^<]*(?i:credential|alias)[^<]*</key>\s*<value>[^<]+</value>' || true; } \
    | sed -E 's#<key>([^<]*)</key>[[:space:]]*<value>([^<]*)</value>#\1\t\2#' \
    | while IFS=$'\t' read -r key val; do
        if [[ $val =~ ^\{\{(.+)\}\}$ ]]; then
          ref=$(jq -r --arg k "${BASH_REMATCH[1]}" \
            '.[] | select(.ParameterKey == $k) | .ParameterValue' "$cfg")
          val=${ref:-$val}
        fi
        [[ -n $val ]] && printf '%s\t%s\n' "$key" "$val"
      done | LC_ALL=C sort -u
}

export_iflow_extras() { # id artifact_dir
  local url="$API/api/v1/IntegrationDesigntimeArtifacts(Id='$1',Version='active')/Configurations"
  http_get "$url" "$TMP/cfg.json" || return 1
  jq -S '[.d.results[] | {ParameterKey, ParameterValue, DataType}] | sort_by(.ParameterKey)' \
    "$TMP/cfg.json" > "$2/configuration.json"
  security_refs "$2/content" "$2/configuration.json" > "$2/security-refs.tsv"
  [[ -s $2/security-refs.tsv ]] || rm -f "$2/security-refs.tsv"
}

# A released artifact has a version like 1.0.3. Anything else (CPI reports
# e.g. "Active" for an artifact saved without a version) is likely a draft.
# Prints "folder/Id (Version X)" lines for those.
draft_suspects() { # artifacts.jsonl (lines of {Folder, Row})
  jq -r 'select((.Row.Version // "" | tostring) | test("^[0-9]+(\\.[0-9]+)*$") | not)
         | "\(.Folder)/\(.Row.Id) (Version \(.Row.Version // "none"))"' "$1"
}

# README.md from the package and artifact metadata.
# Input: $pkg (package.json), $arts (lines of {Folder, Row}), $tenant, $haszip, $stamp.
README_JQ=$(cat <<'EOF'
def str: if . == null then "" elif type == "string" then .
  elif type == "boolean" then (if . then "True" else "False" end) else tostring end;
def truthy: . != null and . != false and . != "" and . != 0;
def cell: str | gsub("<[^>]*>"; " ") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
  | gsub("\\|"; "\\|");
def change($date; $by):
  ([$date | str | match("[0-9]{10,}") | .string | tonumber / 1000 | floor | strftime("%Y-%m-%d")][0] // "") as $d
  | ($by | cell) as $who
  | if $d != "" and $who != "" then "\($d) by \($who)" else $d + $who end;

$pkg[0] as $p
| ($p.Id | str) as $id
| ($p.Name | cell | if . == "" then $id else . end) as $title
| ["# \($title)"]
| reduce (($p.ShortText | cell), ($p.Description | cell)) as $t (.;
    if $t != "" and (any(.[]; . == $t) | not) then . + ["", $t] else . end)
| . + ["", "| | |", "|---|---|"]
| . + [["Package ID", "`\($id)`"], ["Tenant", "`\($tenant)`"],
       ["Version", ($p.Version | cell)], ["Vendor", ($p.Vendor | cell)], ["Mode", ($p.Mode | cell)],
       ["Created", change($p.CreationDate; $p.CreatedBy)],
       ["Last modified", change($p.ModifiedDate; $p.ModifiedBy)],
       ["Downloaded", $stamp]
       | select(.[1] != "") | "| \(.[0]) | \(.[1]) |"]
| . + ["", "Downloaded from SAP Cloud Integration by cpi-local-archive. The script writes this file on every run, so edits to it are overwritten."]
| reduce (["iflows", "Integration flows"], ["valuemappings", "Value mappings"],
          ["scripts", "Script collections"], ["mappings", "Message mappings"]) as [$f, $heading] (.;
    ([$arts[] | select(.Folder == $f) | .Row] | sort_by(.Id | str)) as $rows
    | if $rows == [] then . else
        any($rows[]; .ModifiedAt | truthy) as $dated
        | . + ["", "## \($heading) (\($rows | length))", ""]
        + (if $dated then ["| Name | Version | Last modified | Description |", "|---|---|---|---|"]
           else ["| Name | Version | Description |", "|---|---|---|"] end)
        + [$rows[] | (.Id | str) as $rid | (.Name | cell | if . == "" then $rid else . end) as $name
           | "| " + ((["[\($name)](\($f)/\($rid)/)" + (if $name != $rid then " (ID `\($rid)`)" else "" end),
                       (.Version | cell)]
                      + (if $dated then [change(.ModifiedAt; .ModifiedBy)] else [] end)
                      + [.Description | cell]) | join(" | ")) + " |"]
      end)
| if $arts == [] then . + ["", "The package has no design-time artifacts."] else . end
| . + ["", "## Restoring", ""]
| if $haszip == "1" then . + [
    "1. In CPI, open **Design**, choose **Import** and select `_export/\($id).zip`."]
  else . + [
    "1. CPI gave no full export of this package. Zip an artifact's `content/` folder, keeping its folder structure.",
    "2. In CPI, upload it as a single artifact into the package."] end
| . + ["Then set the externalized parameters from each iFlow's `configuration.json`, create the security material the iFlows use on the tenant, and deploy."]
| join("\n")
EOF
)

write_readme() { # staging_dir package_id artifacts.jsonl
  local haszip=0
  [[ -f $1/_export/$2.zip ]] && haszip=1
  jq -rn --slurpfile pkg "$1/package.json" --slurpfile arts "$3" \
    --arg tenant "$HOST" --arg haszip "$haszip" --arg stamp "$STAMP" "$README_JQ" > "$1/README.md"
}

# Paths in a package folder that the script owns; everything else is left alone.
MANAGED=(package.json README.md _export)
for entry in "${TYPES[@]}"; do MANAGED+=("${entry#*:}"); done

# Lists the artifacts of a package as {Folder, Row} lines into $TMP/arts.jsonl.
list_artifacts() { # package_id
  local entry entity folder
  : > "$TMP/arts.jsonl"
  for entry in "${TYPES[@]}"; do
    entity=${entry%%:*} folder=${entry#*:}
    odata_list "/api/v1/IntegrationPackages('$1')/$entity" > "$TMP/artifacts.jsonl" || return 1
    jq -c --arg f "$folder" --arg e "$entity" '{Folder: $f, Entity: $e, Row: .}' \
      "$TMP/artifacts.jsonl" >> "$TMP/arts.jsonl"
  done
}

# Tries the full package export into the given file. On failure sets
# EXPORT_ERR to "HTTP <code>: <CPI's message>".
EXPORT_ERR=""
try_export() { # package_id outfile
  EXPORT_ERR=""
  if ! http_get "$API/api/v1/IntegrationPackages('$1')/\$value" "$2" '*/*' quiet; then
    EXPORT_ERR="HTTP $HTTP_CODE: $(error_text "$2")"
  elif ! unzip -tq "$2" >/dev/null 2>&1; then
    EXPORT_ERR="response is not a valid zip: $(error_text "$2")"
  else
    return 0
  fi
  rm -f "$2"
  return 1
}

# --check: one package. Appends to the report arrays.
check_package() { # package_id
  local pid=$1 count suspects
  if ! list_artifacts "$pid"; then
    REPORT_FAIL+=("$pid|cannot list artifacts (see warnings above)|")
    return
  fi
  count=$(wc -l < "$TMP/arts.jsonl")
  suspects=$(draft_suspects "$TMP/arts.jsonl")
  if try_export "$pid" "$TMP/check.zip"; then
    log "  export OK ($count artifacts)"
    REPORT_OK+=("$pid|$count artifacts|$suspects")
  else
    log "  export FAILED: $EXPORT_ERR"
    REPORT_FAIL+=("$pid|$EXPORT_ERR|$suspects")
  fi
  rm -f "$TMP/check.zip"
}

# Builds the package in a staging folder and only replaces the earlier download
# when everything downloaded, so a failed run never deletes archived content.
export_package() { # package_id dir
  local pid=$1 dir=$2 out="$TMP/pkg" pkg_url="$API/api/v1/IntegrationPackages('$1')"
  local row entity folder id adir path
  rm -rf "$out"; mkdir -p "$out/_export"

  http_get "$pkg_url" "$TMP/pkg.json" || return 1
  jq -S ".d | $CLEAN" "$TMP/pkg.json" > "$out/package.json"

  if ! try_export "$pid" "$out/_export/$pid.zip"; then
    if ((STRICT)); then
      warn "  no full export for $pid: $EXPORT_ERR"
      return 1
    fi
    warn "  no full export for $pid, continuing without the .zip: $EXPORT_ERR"
    NOZIP+=("$pid")
  fi

  list_artifacts "$pid" || return 1
  : > "$TMP/readme-artifacts.jsonl"
  while IFS= read -r row; do
    entity=$(jq -r .Entity <<<"$row") folder=$(jq -r .Folder <<<"$row") id=$(jq -r .Row.Id <<<"$row")
    adir="$out/$folder/$id"
    mkdir -p "$adir/content"
    jq -S ".Row | $CLEAN" <<<"$row" > "$adir/artifact.json"
    jq -c --arg f "$folder" '{Folder: $f, Row: .}' "$adir/artifact.json" >> "$TMP/readme-artifacts.jsonl"
    log "  $folder/$id"
    http_get "$API/api/v1/$entity(Id='$id',Version='active')/\$value" "$TMP/artifact.zip" '*/*' \
      || return 1
    unzip -q -o "$TMP/artifact.zip" -d "$adir/content" </dev/null || return 1
    if [[ $entity == IntegrationDesigntimeArtifacts ]]; then
      export_iflow_extras "$id" "$adir" || return 1
    fi
  done < "$TMP/arts.jsonl"
  rmdir "$out/_export" 2>/dev/null || true
  write_readme "$out" "$pid" "$TMP/readme-artifacts.jsonl"

  mkdir -p "$dir"
  for path in "${MANAGED[@]}"; do rm -rf "${dir:?}/$path"; done
  for path in "$out"/*; do mv "$path" "$dir/"; done
}

# --- package list -----------------------------------------------------------
ensure_token
if ((${#PACKAGES[@]} == 0)); then
  odata_list "/api/v1/IntegrationPackages" > "$TMP/packages.jsonl" || die "cannot list packages"
  mapfile -t PACKAGES < <(jq -r .Id "$TMP/packages.jsonl")
fi
if ((${#EXCLUDES[@]})); then
  declare -A SKIP=()
  for pid in "${EXCLUDES[@]}"; do SKIP[$pid]=1; done
  KEEP=()
  for pid in "${PACKAGES[@]}"; do [[ -n ${SKIP[$pid]:-} ]] || KEEP+=("$pid"); done
  PACKAGES=("${KEEP[@]}")
fi

# --- test mode --------------------------------------------------------------
if ((CHECK)); then
  log "Checking ${#PACKAGES[@]} package(s) on $HOST (nothing is written)"
  REPORT_OK=() REPORT_FAIL=()
  for pid in "${PACKAGES[@]}"; do
    ensure_token
    log "Package $pid"
    check_package "$pid"
  done

  # Report on stdout, so it can be redirected to a file.
  printf '\nCheck of %s at %s: %d exportable, %d not exportable\n' \
    "$HOST" "$STAMP" "${#REPORT_OK[@]}" "${#REPORT_FAIL[@]}"
  if ((${#REPORT_FAIL[@]})); then
    printf '\nNOT EXPORTABLE\n'
    for line in "${REPORT_FAIL[@]}"; do
      IFS='|' read -r pid detail suspects <<<"$line"
      printf '  %s\n      %s\n' "$pid" "$detail"
      if [[ -n $suspects ]]; then sed 's/^/      possible draft: /' <<<"$suspects"; fi
    done
  fi
  if ((${#REPORT_OK[@]})); then
    printf '\nEXPORTABLE\n'
    for line in "${REPORT_OK[@]}"; do
      IFS='|' read -r pid detail suspects <<<"$line"
      printf '  %-40s %s\n' "$pid" "$detail"
      if [[ -n $suspects ]]; then sed 's/^/      note, unversioned: /' <<<"$suspects"; fi
    done
  fi
  ((${#REPORT_FAIL[@]} == 0)) || exit 2
  exit 0
fi

# --- download ---------------------------------------------------------------
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd)
((DATED)) && { ROOT="$ROOT/$RUN_DIR"; mkdir -p "$ROOT"; }
log "Downloading ${#PACKAGES[@]} package(s) from $HOST into $ROOT"

FAILED=() NOZIP=() DONE=()
for pid in "${PACKAGES[@]}"; do
  ensure_token
  log "Package $pid"
  dir="$ROOT/$pid"
  if [[ ! $pid =~ ^[A-Za-z0-9_.-]+$ ]]; then
    warn "package id $pid cannot be used as a folder name"
  elif [[ -d $dir && ! -f $dir/package.json && -n $(ls -A "$dir") ]]; then
    warn "$dir is not empty and not an earlier download of a package; move it away"
  elif export_package "$pid" "$dir"; then
    DONE+=("$pid")
    continue
  else
    warn "package $pid failed; its folder was left unchanged"
  fi
  FAILED+=("$pid")
done

{
  printf '\nDownloaded %d of %d package(s) from %s into %s\n' \
    "${#DONE[@]}" "${#PACKAGES[@]}" "$HOST" "$ROOT"
  ((${#NOZIP[@]} == 0)) || printf 'Without full export (.zip), artifacts only: %s\n' "${NOZIP[*]}"
  ((${#FAILED[@]} == 0)) || printf 'Failed: %s\n' "${FAILED[*]}"
} >&2
((${#FAILED[@]} == 0)) || exit 1
