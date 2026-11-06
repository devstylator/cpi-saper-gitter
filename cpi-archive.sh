#!/usr/bin/env bash
# cpi-archive.sh: snapshot SAP Cloud Integration packages into git repositories,
# one repository per package (<dir>/<PackageId>/).
#
# Per package it stores the package metadata, a README.md made from it, the full
# package export (.zip),
# every design-time artifact (iFlows, value mappings, script collections,
# message mappings) unzipped, and for iFlows the configured externalized
# parameters plus the names of referenced security material.
# A run that changes a package becomes one commit and one annotated tag in
# that package's repository.
#
# Requires: bash 4+, curl 7.55+, jq, unzip, git 2.28+ (git-lfs for --lfs,
# python3 for the automatic browser callback of --login).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cpi-archive.sh [options]

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
  -d, --dir DIR           folder for the package repositories (default: the current
                          folder); each package goes to DIR/<PackageId>/
  -p, --package ID        package to archive; repeatable (default: all packages)
      --git-name NAME     commit author name (CPI_GIT_NAME; default: git's user.name)
      --git-email EMAIL   commit author email (CPI_GIT_EMAIL; default: git's user.email)
      --remote PKG=URL    set origin of package PKG's repository to URL; repeatable.
                          With exactly one -p, --remote URL is enough
      --push             push each repository's branch and tags to its origin
      --lfs               store the package .zip files with Git LFS
      --package-tags      also tag v<PackageVersion> when a package changed
      --prune             empty the repositories of packages that no longer exist on
                          the tenant, as a commit (only without -p)
      --no-commit         export only, leave the changes uncommitted
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
# Drop OData noise and deferred navigation properties so metadata diffs stay clean.
CLEAN='del(.__metadata, .ArtifactContent) | with_entries(select(.value | type != "object"))'

ROOT=. PACKAGES=() REMOTE_ARGS=() SERVICE_KEY=""
PUSH=0 LFS=0 PKG_TAGS=0 PRUNE=0 COMMIT=1 LOGIN=0 LOGIN_PORT=8765
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
    -d|--dir|--repo)  ROOT=${2:?"$1 needs a value"}; shift 2 ;;
    -p|--package)     PACKAGES+=("${2:?"$1 needs a value"}"); shift 2 ;;
    --git-name)       CPI_GIT_NAME=${2:?"$1 needs a value"}; shift 2 ;;
    --git-email)      CPI_GIT_EMAIL=${2:?"$1 needs a value"}; shift 2 ;;
    --remote)         REMOTE_ARGS+=("${2:?"$1 needs a value"}"); shift 2 ;;
    --push)           PUSH=1; shift ;;
    --lfs)            LFS=1; shift ;;
    --package-tags)   PKG_TAGS=1; shift ;;
    --prune)          PRUNE=1; shift ;;
    --no-commit)      COMMIT=0; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; die "unknown option: $1" ;;
  esac
done

for cmd in curl jq unzip git; do
  command -v "$cmd" >/dev/null || die "$cmd is not installed"
done
((LFS)) && { git lfs version >/dev/null 2>&1 || die "git-lfs is not installed"; }
((PRUNE)) && ((${#PACKAGES[@]})) && die "--prune only works when archiving all packages"

# Package id -> origin URL, from --remote PKG=URL (or --remote URL with one -p).
declare -A REMOTES=()
for arg in "${REMOTE_ARGS[@]}"; do
  if [[ $arg =~ ^([A-Za-z0-9_.-]+)=(.+)$ ]]; then
    REMOTES[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
  elif ((${#PACKAGES[@]} == 1)); then
    REMOTES[${PACKAGES[0]}]=$arg
  else
    die "--remote $arg: use --remote PACKAGE=URL (plain --remote URL needs exactly one -p)"
  fi
done
if ((${#PACKAGES[@]})); then
  for pid in "${!REMOTES[@]}"; do
    [[ " ${PACKAGES[*]} " == *" $pid "* ]] || die "--remote for $pid, but $pid is not among the -p packages"
  done
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
RUN_TAG="snapshot/$(date -u +%Y%m%d-%H%M%S)"

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
        self.wfile.write(b"cpi-archive.sh: login received, you can close this tab.\n")
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

http_get() { # url outfile [accept]
  local code
  code=$(curl -sS -g -H @"$AUTH_HDR" -H "Accept: ${3:-application/json}" \
    -o "$2" -w '%{http_code}' "$1") || { warn "request failed: $1"; return 1; }
  [[ $code == 2?? ]] || { warn "HTTP $code: $1"; return 1; }
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

# README.md from the package and artifact metadata, so the repository page
# shows what the package holds. It uses no run time or date, so an unchanged
# package gets the same README and no commit. Same text as cpi-archive.ps1.
# Input: $pkg (package.json), $arts (lines of {Folder, Row}), $tenant, $haszip.
README_JQ=$(cat <<'EOF'
# a value as text, as PowerShell's [string] gives it
def str: if . == null then "" elif type == "string" then .
  elif type == "boolean" then (if . then "True" else "False" end) else tostring end;
def truthy: . != null and . != false and . != "" and . != 0;
# Markdown table cell: one line of plain text, without HTML tags and pipes.
def cell: str | gsub("<[^>]*>"; " ") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
  | gsub("\\|"; "\\|");
# CPI dates are milliseconds since 1970 ("1713342313195" or "/Date(1713342313195)/").
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
       ["Last modified", change($p.ModifiedDate; $p.ModifiedBy)]
       | select(.[1] != "") | "| \(.[0]) | \(.[1]) |"]
| . + ["", "Archived from SAP Cloud Integration by cpi-archive. Every change in CPI is one commit with a `snapshot/YYYYMMDD-HHMMSS` tag. The script writes this file on every run, so edits to it are overwritten."]
# folder : heading, in the order of TYPES
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
    "1. Take the package export from the snapshot you need (with Git LFS, run `git lfs pull` first):",
    "   `git show snapshot/<YYYYMMDD-HHMMSS>:_export/\($id).zip > \($id).zip`",
    "2. In CPI, open **Design**, choose **Import** and select the zip."]
  else . + [
    "1. CPI gave no full export of this package. Zip an artifact's `content/` folder from the snapshot you need, keeping its folder structure.",
    "2. In CPI, upload it as a single artifact into the package."] end
| . + ["3. Set the externalized parameters from each iFlow's `configuration.json` of the same snapshot.",
       "4. Create the security material the iFlows use on the tenant, then deploy."]
| join("\n")
EOF
)

write_readme() { # staging_dir package_id artifacts.jsonl
  local haszip=0
  [[ -f $1/_export/$2.zip ]] && haszip=1
  jq -rn --slurpfile pkg "$1/package.json" --slurpfile arts "$3" \
    --arg tenant "$HOST" --arg haszip "$haszip" "$README_JQ" > "$1/README.md"
}

# Paths in a package repository that the script owns; everything else
# (.gitignore, ...) is left alone.
MANAGED=(package.json README.md _export)
for entry in "${TYPES[@]}"; do MANAGED+=("${entry#*:}"); done

# Refuses folders that would lose or mix up content: non-git folders with files
# and repositories with uncommitted changes.
check_repo() { # dir
  if [[ -d $1/.git ]]; then
    [[ -z $(git -C "$1" status --porcelain) ]] \
      || { warn "$1 has uncommitted changes; commit or discard them first"; return 1; }
  elif [[ -d $1 && -n $(ls -A "$1") ]]; then
    warn "$1 is not empty and not a git repository"; return 1
  fi
}

init_repo() { # dir package_id
  if [[ ! -d $1/.git ]]; then
    log "  creating repository $1"
    mkdir -p "$1"
    git -C "$1" init -q -b main
    # Store files byte for byte: no line-ending conversion of scripts or XML.
    printf '* -text\n' > "$1/.gitattributes"
  fi
  if ((LFS)); then
    git -C "$1" lfs install --local >/dev/null
    git -C "$1" lfs track '_export/*.zip' >/dev/null
  fi
  local url=${REMOTES[$2]:-} current
  [[ -n $url ]] || return 0
  current=$(git -C "$1" remote get-url origin 2>/dev/null || true)
  if [[ -z $current ]]; then
    git -C "$1" remote add origin "$url"
    log "  origin set to $url"
  elif [[ $current != "$url" ]]; then
    git -C "$1" remote set-url origin "$url"
    log "  origin changed from $current to $url"
  fi
}

# Builds the package in a staging folder and only replaces the archived copy
# when everything downloaded, so a failed run never deletes archived content.
export_package() { # package_id dir
  local pid=$1 dir=$2 out="$TMP/pkg" pkg_url="$API/api/v1/IntegrationPackages('$1')"
  local entry entity folder row id adir path
  rm -rf "$out"; mkdir -p "$out/_export"
  : > "$TMP/readme-artifacts.jsonl"

  http_get "$pkg_url" "$TMP/pkg.json" || return 1
  jq -S ".d | $CLEAN" "$TMP/pkg.json" > "$out/package.json"

  if ! http_get "$pkg_url/\$value" "$out/_export/$pid.zip" '*/*'; then
    warn "  no full export for $pid (configure-only SAP content?), continuing without the .zip"
    rm -f "$out/_export/$pid.zip"
  fi

  for entry in "${TYPES[@]}"; do
    entity=${entry%%:*} folder=${entry#*:}
    odata_list "/api/v1/IntegrationPackages('$pid')/$entity" > "$TMP/artifacts.jsonl" || return 1
    while IFS= read -r row; do
      id=$(jq -r .Id <<<"$row")
      adir="$out/$folder/$id"
      mkdir -p "$adir/content"
      jq -S "$CLEAN" <<<"$row" > "$adir/artifact.json"
      jq -c --arg f "$folder" '{Folder: $f, Row: .}' "$adir/artifact.json" >> "$TMP/readme-artifacts.jsonl"
      log "  $folder/$id"
      http_get "$API/api/v1/$entity(Id='$id',Version='active')/\$value" "$TMP/artifact.zip" '*/*' \
        || return 1
      unzip -q -o "$TMP/artifact.zip" -d "$adir/content" </dev/null || return 1
      if [[ $entity == IntegrationDesigntimeArtifacts ]]; then
        export_iflow_extras "$id" "$adir" || return 1
      fi
    done < "$TMP/artifacts.jsonl"
  done
  write_readme "$out" "$pid" "$TMP/readme-artifacts.jsonl"

  init_repo "$dir" "$pid" || return 1
  for path in "${MANAGED[@]}"; do rm -rf "${dir:?}/$path"; done
  for path in "$out"/*; do mv "$path" "$dir/"; done
}

# The export .zip differs on every download (timestamps). If nothing else in the
# package changed, keep the committed .zip so unchanged packages create no commit.
keep_zip_if_unchanged() { # dir package_id
  local zip="_export/$2.zip"
  git -C "$1" rev-parse -q --verify "HEAD:$zip" >/dev/null || return 0
  [[ -z $(git -C "$1" status --porcelain -- . ":(exclude)_export") ]] || return 0
  git -C "$1" checkout -q HEAD -- "$zip"
}

commit_package() { # dir package_id [subject]
  local dir=$1 pid=$2 subject=${3:-"Snapshot of $2 from $HOST at $STAMP"} changed ver tag
  git -C "$dir" add -A || return 1
  if git -C "$dir" diff --cached --quiet; then
    log "  no changes since the last snapshot"
    return 0
  fi
  changed=$(git -C "$dir" diff --cached --name-only \
    | awk -F/ 'NF > 2 && $1 != "_export" { print $1 "/" $2 }' | LC_ALL=C sort -u)
  {
    printf '%s\n' "$subject"
    if [[ -n $changed ]]; then
      printf '\nChanged artifacts:\n'
      sed 's/^/- /' <<<"$changed"
    fi
  } > "$TMP/commit-msg"
  git "${GIT_ID[@]}" -C "$dir" commit -q -F "$TMP/commit-msg" || return 1
  git "${GIT_ID[@]}" -C "$dir" tag -a "$RUN_TAG" -m "$pid from $HOST at $STAMP" || return 1
  log "  committed and tagged $RUN_TAG"

  ((PKG_TAGS)) && [[ -f $dir/package.json ]] || return 0
  ver=$(jq -r '.Version // empty' "$dir/package.json")
  tag="v$ver"
  if [[ -z $ver ]]; then
    return 0
  elif ! git check-ref-format "tags/$tag"; then
    warn "  cannot use $tag as a tag name"
  elif git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    warn "  $pid changed but its version $ver is already tagged (version not raised in CPI?)"
  else
    git "${GIT_ID[@]}" -C "$dir" tag -a "$tag" -m "$pid $ver, snapshot $STAMP" || return 1
    log "  tagged $tag"
  fi
}

# Pushes on every run, not only after a new commit, so a push that failed
# earlier (remote repository not created yet, network) is caught up later.
push_package() { # dir
  git -C "$1" rev-parse -q --verify HEAD >/dev/null || return 0
  git -C "$1" remote get-url origin >/dev/null 2>&1 \
    || { warn "  no origin to push to (use --remote PACKAGE=URL)"; return 1; }
  git -C "$1" push -q -u --follow-tags origin HEAD || { warn "  push to origin failed"; return 1; }
  log "  pushed"
}

# --- checks -----------------------------------------------------------------
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd)
if [[ -d $ROOT/.git ]]; then
  die "$ROOT is a git repository itself; use a plain folder (each package gets its own repository inside)"
fi
# Resolve the commit identity now, so a missing one fails before the export.
GIT_NAME=${CPI_GIT_NAME:-$(git -C "$ROOT" config user.name || true)}
GIT_EMAIL=${CPI_GIT_EMAIL:-$(git -C "$ROOT" config user.email || true)}
if ((COMMIT)) && [[ -z $GIT_NAME || -z $GIT_EMAIL ]]; then
  die "no git identity: use --git-name/--git-email or set git's user.name/user.email"
fi
GIT_ID=(-c "user.name=$GIT_NAME" -c "user.email=$GIT_EMAIL")

# --- export, commit, push ---------------------------------------------------
ensure_token
if ((${#PACKAGES[@]} == 0)); then
  odata_list "/api/v1/IntegrationPackages" > "$TMP/packages.jsonl" || die "cannot list packages"
  mapfile -t PACKAGES < <(jq -r .Id "$TMP/packages.jsonl")
fi
log "Archiving ${#PACKAGES[@]} package(s) from $HOST into $ROOT"

FAILED=()
declare -A SEEN=()
for pid in "${PACKAGES[@]}"; do
  SEEN[$pid]=1
  ensure_token
  log "Package $pid"
  dir="$ROOT/$pid"
  if [[ ! $pid =~ ^[A-Za-z0-9_.-]+$ ]]; then
    warn "package id $pid cannot be used as a folder name"
  elif check_repo "$dir" && export_package "$pid" "$dir"; then
    keep_zip_if_unchanged "$dir" "$pid"
    if ((COMMIT == 0)) || { commit_package "$dir" "$pid" && { ((PUSH == 0)) || push_package "$dir"; }; }; then
      continue
    fi
  else
    warn "package $pid failed; its repository was left unchanged"
  fi
  FAILED+=("$pid")
done

if ((PRUNE)); then
  for dir in "$ROOT"/*/; do
    dir=${dir%/} pid=$(basename "$dir")
    [[ -d $dir/.git && -f $dir/package.json && -z ${SEEN[$pid]:-} ]] || continue
    log "Package $pid no longer exists on the tenant, emptying its repository"
    check_repo "$dir" || { FAILED+=("$pid"); continue; }
    for path in "${MANAGED[@]}"; do rm -rf "${dir:?}/$path"; done
    ((COMMIT)) || continue
    commit_package "$dir" "$pid" "Package $pid deleted on $HOST (seen at $STAMP)" \
      && { ((PUSH == 0)) || push_package "$dir"; } || FAILED+=("$pid")
  done
fi

if ((COMMIT == 0)); then
  log "Export done, changes left uncommitted in the package repositories"
fi
if ((${#FAILED[@]})); then
  warn "failed: ${FAILED[*]}"
  exit 1
fi
