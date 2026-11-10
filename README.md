# cpi-archive

Archives SAP Cloud Integration packages into git, **one repository per package**. It covers all artifact types, not only iFlows.

There are two versions with the same options: `cpi-archive.sh` for Linux (see [Linux (bash)](#linux-bash)), and `cpi-archive.ps1` for Windows (see [Windows (PowerShell)](#windows-powershell)). Both write identical files, including the package `README.md`, so the same archive can be updated from either system. The examples in this document use `cpi-archive.sh`.

Each run saves the current design-time state of the packages. If a package changed since the last run, its repository gets one commit and one tag, so each package's history is a list of versions you can restore.

## Layout

Run the script in a plain folder, for example one folder per tenant. Each package gets its own repository inside it:

```
cpi-dev/                  plain folder, not a repository
├── MyPackage/            repository of this package
│   ├── .git/
│   ├── README.md
│   ├── package.json
│   ├── _export/MyPackage.zip
│   └── iflows/ ...
└── OtherPackage/         repository of this package
    └── ...
```

## What gets archived

In each package repository:

| Item | Where |
|---|---|
| Package metadata | `package.json` |
| Overview of the package and its artifacts, made from the metadata | `README.md` |
| Full package export (import it into CPI to restore) | `_export/<Package>.zip` |
| iFlows, unzipped | `iflows/<Id>/content/` |
| Value mappings, unzipped | `valuemappings/<Id>/content/` |
| Script collections, unzipped | `scripts/<Id>/content/` |
| Message mappings, unzipped | `mappings/<Id>/content/` |
| Artifact metadata (name, version, ...) | `<type>/<Id>/artifact.json` |
| iFlow externalized parameters, with the values set on the tenant | `iflows/<Id>/configuration.json` |
| Credential and key alias names used by an iFlow | `iflows/<Id>/security-refs.tsv` |

The script only touches these paths. Other files you add to a package repository, such as a `.gitignore`, are left alone. `README.md` is written again on every run, so put your own notes in another file.

The script does **not** archive:
- **Security material.** Passwords, keystore entries and OAuth clients cannot be exported. `security-refs.tsv` only lists their names, so you know what to recreate.
- **Runtime state.** Deployed status, message processing logs, data stores and variables stay on the tenant.

## Requirements

- An API client for the tenant (next section)
- The tools for your system: see [Linux (bash)](#linux-bash) or [Windows (PowerShell)](#windows-powershell)

## Credentials

### Cloud Foundry (OAuth)

1. In the BTP subaccount, create a **Process Integration Runtime** service instance with plan **`api`** and grant type **Client Credentials**.
2. Give it read roles for design-time packages and artifacts. If package or artifact downloads return HTTP 403, check the role list in the SAP documentation for the API client and add what is missing.
3. Create a service key and save it as JSON, for example `prod-key.json`. The script reads `oauth.url`, `oauth.tokenurl`, `oauth.clientid` and `oauth.clientsecret` from it.

```bash
chmod 600 prod-key.json
```

### Options or environment variables instead of a key file

Pass the values from the service key as options:

```bash
./cpi-archive.sh \
  --api-url https://<tenant>.it-cpi0xx.cfapps.<region>.hana.ondemand.com \
  --token-url https://<subdomain>.authentication.<region>.hana.ondemand.com/oauth/token \
  --client-id '<clientid>'
```

Or set them as environment variables:

```bash
export CPI_API_URL=https://<tenant>.it-cpi0xx.cfapps.<region>.hana.ondemand.com
export CPI_TOKEN_URL=https://<subdomain>.authentication.<region>.hana.ondemand.com/oauth/token
export CPI_CLIENT_ID=...
export CPI_CLIENT_SECRET=...
```

You can combine the two methods. Options take precedence over `--service-key`, and `--service-key` takes precedence over the environment. Quote the client ID, because it contains `!` and `|`. `--client-secret` also works, but other users can see it in the process list, so set the secret with `CPI_CLIENT_SECRET` instead.

For basic auth (Neo), set `CPI_API_URL`, `CPI_USER` and `CPI_PASSWORD` instead.

### Browser login (authorization code)

With `--login`, the script calls the API as you, not as a technical client. Access then depends on your own role collections in the subaccount.

1. Create the **Process Integration Runtime** instance (plan **`api`**) with grant type **Authorization Code**, plus **Refresh Token** for long runs, and register the redirect URI. As JSON parameters:

   ```json
   {
     "grant-types": ["authorization_code", "refresh_token"],
     "redirect-uris": ["http://localhost:8765/callback"]
   }
   ```

2. Create a service key as usual. The login still needs the client ID and secret.
3. Run with `--login`:

   ```bash
   ./cpi-archive.sh -k login-key.json --login -p MyPackage
   ```

The script opens the XSUAA login page in your browser and waits up to 5 minutes for the redirect to `http://localhost:8765/callback`. It then exchanges the code for a token. It renews the token with the refresh token while it runs, and asks you to log in again only if that fails. Nothing is stored on disk, so every run starts with a login. `--login` does not work from cron. For scheduled runs, use client credentials.

- **Different port:** use `--login-port PORT`. Register the matching redirect URI, `http://localhost:PORT/callback`.
- **Remote machine over SSH:** forward the port with `ssh -L 8765:localhost:8765 <host>`, then open the printed URL in your local browser.
- **No python3:** the script prints the URL. Your browser can't load the redirect page after the login. Copy the full address from the address bar and paste it into the terminal.


## First run

By default, the script uses the folder you run it from. That folder must not be a git repository itself. Each package folder inside it must be empty, missing, or a package repository from an earlier run.

1. Create the folder and try a single package first:

   ```bash
   mkdir ~/cpi-dev && cd ~/cpi-dev
   /path/to/cpi-archive.sh -k prod-key.json -p MyPackage --lfs
   ```

2. Check the result:

   ```bash
   cd MyPackage
   git log --oneline
   git tag
   ```

3. To push, create an **empty private** repository on GitHub or GitLab for each package. Name them however you like. The script does not create remote repositories.
4. Give each package its repository URL with `--remote PACKAGE=URL`, and push:

   ```bash
   /path/to/cpi-archive.sh -k prod-key.json --lfs --push \
     --remote MyPackage=https://github.com/<you>/my-package-archive.git \
     --remote OtherPackage=git@gitlab.com:<group>/other.git
   ```

   For a run with exactly one `-p`, `--remote URL` without the package name is enough:

   ```bash
   /path/to/cpi-archive.sh -k prod-key.json -p MyPackage --remote https://github.com/<you>/my-package-archive.git --push
   ```

   The URL is saved as the repository's `origin`, so later runs only need `--push`. Pass `--remote` again with a different URL to change it. Packages without an `origin` are not pushed; the script warns about them.

To use a folder other than the current one, use `-d DIR`.

## Options

| Option | Meaning |
|---|---|
| `-k`, `--service-key FILE` | Read the URL and OAuth data from a BTP service key |
| `--api-url URL` | API base URL (`CPI_API_URL`) |
| `--token-url URL` | OAuth token URL (`CPI_TOKEN_URL`) |
| `--client-id ID` | OAuth client ID (`CPI_CLIENT_ID`) |
| `--client-secret SECRET` | OAuth client secret (`CPI_CLIENT_SECRET`). Visible in the process list, so prefer the variable |
| `--login` | Log in as a user in the browser (OAuth authorization code) instead of using client credentials |
| `--login-port PORT` | Local port for the login redirect (default `8765`) |
| `-d`, `--dir DIR` | Folder for the package repositories (default: the current folder). Each package goes to `DIR/<PackageId>/` |
| `-p`, `--package ID` | Archive only this package; can be repeated. Without it, all packages are archived |
| `--git-name NAME` | Commit and tag author name (`CPI_GIT_NAME`). Default: git's `user.name` |
| `--git-email EMAIL` | Commit and tag author email (`CPI_GIT_EMAIL`). Default: git's `user.email` |
| `--remote PACKAGE=URL` | Set `origin` of that package's repository to URL (added, or changed if it differs). Repeatable. With exactly one `-p`, `--remote URL` is enough |
| `--push` | Push each package repository's branch and tags to its `origin` |
| `--lfs` | Store the package zips with Git LFS |
| `--package-tags` | Also add a tag `v<Version>` when a package changed |
| `--prune` | Empty the repositories of packages that no longer exist on the tenant, as a commit (only when archiving all packages) |
| `--no-commit` | Export only and leave the changes uncommitted, to inspect them first |
| `-h`, `--help` | Show the help |

## Updating the archive

Run the same command again from the same folder. The script rebuilds each package from the tenant and lets git work out the differences, separately for each package repository:

| Situation | Result |
|---|---|
| Package changed | One commit in that package's repository, listing the changed artifacts, plus a tag `snapshot/YYYYMMDD-HHMMSS` (UTC). All packages changed in the same run share the tag name |
| Package unchanged | No commit, no tag |
| Package unchanged but re-exported | The old zip is kept, because the export zip differs on every download (timestamps) |
| Artifact deleted in CPI | Removed in the new commit; still in history |
| New package in CPI | A new repository is created for it |
| Package deleted in CPI | Its repository is kept. With `--prune`, its content is removed in a final commit; the history stays |
| Package failed to download | Its repository is left as it was, the other packages continue, and the exit code is 1 |
| Push failed | Reported, and the exit code is 1. The next run with `--push` pushes again, even if nothing changed |

The script skips a package if its repository has uncommitted changes. Commit them or discard them first.

To run it on a different machine, `git clone` the package repositories into one folder and run the script there.

### Scheduling

Example: every night at 02:00, using `crontab -e`:

```
0 2 * * * /home/<you>/bin/cpi-archive.sh -k /home/<you>/keys/prod-key.json -d /home/<you>/cpi-dev --lfs --push >> /home/<you>/cpi-archive.log 2>&1
```

Cron has no SSH agent, so `--push` needs a deploy key or another SSH key that works without a passphrase prompt.

## Working with the archive

All commands run inside a package repository, for example `cd ~/cpi-dev/MyPackage`.

To see what changed between two snapshots:

```bash
git diff snapshot/20261103-020000 snapshot/20261110-020000 --stat
git diff snapshot/20261103-020000 snapshot/20261110-020000 -- iflows/
```

To see one iFlow's history:

```bash
git log --oneline -- iflows/MyIflow/
```

To restore a package:

1. Take the zip from the snapshot you want:

   ```bash
   git show snapshot/20261103-020000:_export/MyPackage.zip > ~/MyPackage.zip
   ```

   With LFS, run `git lfs pull` first, or check out the tag and copy the file from there.
2. In CPI, go to **Design** and choose **Import**, then select the zip.
3. Set the externalized parameters again, using `configuration.json` from the same snapshot.
4. Recreate the security material listed in `security-refs.tsv`.
5. Deploy.

If the package zip is missing for a snapshot (see Troubleshooting), use the unzipped artifact in `content/`. Zip it again, keeping the folder structure, and upload it as a single artifact.

`cpi-import.ps1` does these steps for you (see the next section).

## Importing a package into a tenant

`cpi-import.ps1` is the opposite of the archive script. It takes one package from the archive and imports it into a tenant, for example to restore a snapshot or to bring a package from DEV to QA. It is available for Windows only.

The source is one of the following:

| Source | Example |
|---|---|
| A local package repository | `-Path C:\cpi\cpi-dev\MyPackage` |
| A folder of package repositories, plus the package | `-Path C:\cpi\cpi-dev -Package MyPackage` |
| A remote package repository (cloned into `%TEMP%` and deleted afterwards) | `-GitUrl https://gitlab.example.com/archive/mypackage.git` |
| A package export zip | `-Path .\MyPackage.zip` |

Add `-Ref snapshot/YYYYMMDD-HHMMSS` (or any tag, branch or commit) to import an older state. For a local repository, the script checks the ref out into a temporary worktree, so your working tree stays as it is. Without `-Ref`, a local repository is imported as it is on disk, including uncommitted changes. If the zip is stored with Git LFS, the script fetches it.

```powershell
# Check first: shows the package, the target tenant and whether the package already exists there
.\cpi-import.ps1 -k qa-key.json -Path C:\cpi\cpi-dev\MyPackage -DryRun

# Import an older snapshot from the remote repository, replace the package and deploy it
.\cpi-import.ps1 -k qa-key.json -GitUrl https://gitlab.example.com/archive/mypackage.git `
  -Ref snapshot/20261110-072909 -Overwrite -Deploy
```

| Option | Meaning |
|---|---|
| `-Path PATH` | Local source: package repository, folder of repositories, or export zip |
| `-GitUrl URL` | Remote source: package repository URL |
| `-Ref REF` | Tag, branch or commit to import (with a repository) |
| `-p`, `-Package ID` | Package to take from a folder of package repositories |
| `-FromContent` | Create the package from `package.json` and upload each artifact from its `content/` folder, instead of importing `_export/<Package>.zip`. This is used automatically when the zip is missing |
| `-Overwrite` | Replace the package if it already exists on the tenant. Without it, the import stops |
| `-ApplyConfiguration` | Set the iFlow externalized parameters from each `configuration.json` |
| `-Deploy` | Deploy the artifacts (script collections, value mappings, message mappings, then iFlows) and wait for the result |
| `-DeployTimeout SEC` | Seconds to wait for each deployment (default 300) |
| `-DryRun` | Show what would be done and change nothing |

The connection options (`-k`, `-ApiUrl`, `-Login`, ...) and environment variables are the same as for `cpi-archive.ps1`. The API client needs write access to design-time content, and deploy access if you use `-Deploy`.

Notes:

- **Overwriting works in two ways.** CPI replaces a package from a zip only if the package on the tenant came from an import of the same package. If it was created there in another way, CPI refuses with "artifacts with the same ID", and the script updates the artifacts one by one from their folders. Artifacts that are on the tenant but not in the archive are left in place and listed as warnings. A plain zip has no artifact folders, so in that case, delete the package on the tenant first.
- **Parameter values come from the source tenant.** `-ApplyConfiguration` writes the values archived from the tenant you exported from. Endpoints and other tenant-specific values usually need to change for another tenant, so check them before you use the option.
- **Security material is not imported.** At the end, the script lists the credential and key names from `security-refs.tsv`. Create any that are missing on the target tenant before you deploy.

## Linux (bash)

`cpi-archive.sh` needs:

- bash 4+, `curl` 7.55+, `jq`, `unzip`, `git` 2.28+ and GNU grep
- `git-lfs`, if you use `--lfs` (recommended)
- `python3` and `xdg-open`, if you use `--login` (without python3 you paste the redirect address by hand)

Install them with your package manager:

```bash
sudo dnf install jq unzip git git-lfs python3        # Fedora, RHEL
sudo apt install curl jq unzip git git-lfs python3   # Debian, Ubuntu
```

### Running it

Make the script executable once, then run it from the archive folder:

```bash
chmod +x cpi-archive.sh
mkdir ~/cpi-dev && cd ~/cpi-dev

/path/to/cpi-archive.sh -k ~/.cpi/dev-key.json --login --lfs \
  -p MyPackage \
  --remote https://github.com/<you>/MyPackage.git --push \
  --git-name "Your Name" --git-email "you@example.com"
```

`-h` shows the help with all options (see [Options](#options)).

### Notes for Linux

- **macOS** works too, but its built-in bash is 3.2 and its grep is not GNU grep. Install `bash` and `grep` with Homebrew and make sure they come first in `PATH`.
- **Pushing over HTTPS** needs a credential helper or a token in the URL; for unattended runs, use SSH URLs with a deploy key (see [Scheduling](#scheduling)).
- **Browser login** uses `xdg-open` (or `open` on macOS) to open the login page. If neither works, open the printed URL yourself.
- **While it runs**, the script keeps its temporary files in a private folder from `mktemp -d` and deletes it on exit.

## Windows (PowerShell)

`cpi-archive.ps1` does the same as `cpi-archive.sh`. It needs:

- Windows PowerShell 5.1 (built into Windows 10 and 11) or PowerShell 7+
- [Git for Windows](https://git-scm.com/download/win), which includes Git LFS and the Git Credential Manager for HTTPS pushes

It needs nothing else. Downloads, unzipping, JSON and the browser login use PowerShell itself.

### Running it

Windows blocks downloaded scripts by default. Either unblock the file once, or start it with a bypass for that run:

```powershell
Unblock-File .\cpi-archive.ps1                                     # once
powershell -ExecutionPolicy Bypass -File .\cpi-archive.ps1 -h      # or per run
```

Example, run from the archive folder:

```powershell
mkdir C:\cpi\cpi-dev; cd C:\cpi\cpi-dev

& C:\path\to\cpi-archive.ps1 -k $HOME\.cpi\dev-key.json -Login -Lfs `
  -p MyPackage `
  -Remote https://github.com/<you>/MyPackage.git -Push `
  -GitName "Your Name" -GitEmail "you@example.com"
```

Start the script with `&` (the call operator) whenever its path is quoted or contains spaces, for example `& 'C:\My Tools\cpi-archive.ps1' -h`. Without `&`, PowerShell reads a quoted path as a string and reports `Unexpected token '-k' in expression or statement`.

`-h` shows the help, and `Get-Help .\cpi-archive.ps1 -Detailed` shows it with all parameters.

### Options

The options are the same, written the PowerShell way. Lists use commas instead of a repeated option:

| `cpi-archive.sh` | `cpi-archive.ps1` |
|---|---|
| `-k`, `--service-key FILE` | `-k`, `-ServiceKey FILE` |
| `--api-url URL` | `-ApiUrl URL` |
| `--token-url URL` | `-TokenUrl URL` |
| `--client-id ID` | `-ClientId ID` |
| `--client-secret SECRET` | `-ClientSecret SECRET` |
| `--login` | `-Login` |
| `--login-port PORT` | `-LoginPort PORT` |
| `-d`, `--dir DIR` | `-d`, `-Dir DIR` |
| `-p A -p B` | `-p A,B` (or `-Package A,B`) |
| `--git-name NAME` / `--git-email EMAIL` | `-GitName NAME` / `-GitEmail EMAIL` |
| `--remote A=URL --remote B=URL` | `-Remote A=URL,B=URL` |
| `--push` | `-Push` |
| `--lfs` | `-Lfs` |
| `--package-tags` | `-PackageTags` |
| `--prune` | `-Prune` |
| `--no-commit` | `-NoCommit` |
| `-h`, `--help` | `-h`, `-Help` |

The environment variables are the same (`CPI_API_URL`, `CPI_CLIENT_SECRET`, `CPI_GIT_NAME`, ...). In PowerShell, set them with `$env:CPI_CLIENT_SECRET = '...'`.

### Notes for Windows

- **Use a short archive path**, such as `C:\cpi\cpi-dev`. iFlow content paths are long, and Windows limits paths to 260 characters unless long paths are enabled. The script sets `core.longpaths` for git in every package repository, but PowerShell 5.1 itself may still fail on very long paths. If you see "path too long" errors, enable long paths (Group Policy **Enable Win32 long paths**, or the registry value `LongPathsEnabled`), or use PowerShell 7.
- **Pushing over HTTPS** works without extra setup: Git Credential Manager opens a browser window for the GitHub login on the first push.
- **Browser login** opens your default browser. The redirect listener runs on `127.0.0.1` and needs no administrator rights.
- **While it runs**, the script keeps a temporary folder `.cpi-archive-tmp-*` in the archive folder and deletes it at the end.

## Troubleshooting

| Message | Cause |
|---|---|
| `token request ... failed` | Wrong token URL, client ID or secret |
| Login page shows an invalid redirect error | With `--login`: `http://localhost:<port>/callback` is not in the instance's `redirect-uris`, or the instance lacks the `authorization_code` grant type |
| `cannot listen on port ...` | With `--login`: another program uses the port. Pick another with `--login-port` and register it as a redirect URI |
| `HTTP 403` after `--login` | Your user lacks the Cloud Integration role collections for reading design-time content |
| `HTTP 401` | Token or credentials rejected |
| `HTTP 403` | The API client is missing a role |
| `no full export for <Package>` | The package cannot be exported as a whole. This is typical for configure-only SAP standard content. The artifacts are still archived when the API allows it |
| `HTTP 404` on `MessageMappingDesigntimeArtifacts` | The tenant does not offer that API, so the package fails. Remove that line from `TYPES` in the script |
| `version ... is already tagged` | With `--package-tags`: the package changed, but its version was not raised in CPI |
| `has uncommitted changes` | Commit or discard the changes in that package repository |
| `is not empty and not a git repository` | A folder with the package's name exists but is not a package repository. Move it away |
| `is a git repository itself` | You ran the script inside a repository, such as an archive from the old single-repository layout. Use a plain folder |
| `no git identity` | Pass `--git-name` and `--git-email`, or set git's `user.name` and `user.email` |
| `no origin to push to` | With `--push`: give that package a URL with `--remote PACKAGE=URL` |
| `push to origin failed` | The remote repository doesn't exist yet, or your key has no write access to it |

## Security notes

- **Keep the repositories private.** They contain the tenant host name (in commit messages and tags) and the values of all externalized parameters. If anyone put a secret into a parameter, it is stored in plain text in `configuration.json`.
- **Protect the service key** (`chmod 600`) and keep it outside the archive repository.
- **Credentials do not show up in the process list**, unless you pass `--client-secret`. The script gives them to curl through its standard input and a temporary file that it deletes when it exits. This also covers the login code and the refresh token.
- **The login callback listens on 127.0.0.1 only** and checks a random `state` value, so a redirect from another login attempt is rejected.
- **`security-refs.tsv` is a heuristic.** It matches iFlow properties whose key contains "credential" or "alias". Check it before relying on it for a restore.
