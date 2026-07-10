# deploy_hph/ — Deploy the MCP Server on IIS with **HttpPlatformHandler**

Automated, **TDD-built** tooling to check + install prerequisites and deploy the
GIS PostgreSQL MCP Server on **IIS using the HttpPlatformHandler (HPH) module**.

In HPH mode **IIS itself launches and manages the Python process** and proxies
requests to it — so you do **not** need ARR, URL Rewrite, or NSSM. This is the
simpler alternative to the `../deploy/` (ARR + NSSM) tooling.

> **Sibling of** [`../docs/`](../docs/) and [`../deploy/`](../deploy/). Related
> background: [../docs/DEPLOYMENT_IIS_WINDOWS_SERVER.md](../docs/DEPLOYMENT_IIS_WINDOWS_SERVER.md)
> (Appendix A covers HttpPlatformHandler).
>
> **No existing app source is modified.** The only files added to the project
> root at deploy time are `run_http.py` and `web.config`.

---

## HPH vs. ARR/NSSM — what changes

| Concern | `../deploy` (ARR + NSSM) | `deploy_hph` (this folder) |
|---------|-------------------------|----------------------------|
| Reverse proxy | ARR + URL Rewrite | **HttpPlatformHandler** (built-in forwarder) |
| Process manager | NSSM Windows Service | **IIS app pool** (starts/stops/recycles Python) |
| ASGI server (uvicorn) | required | **still required** — HPH does not replace it |
| Installs needed | Python, URL Rewrite, ARR, NSSM, uvicorn | **Python, HttpPlatformHandler, uvicorn** |
| Streaming (SSE) control | fine-grained (ARR timeouts/buffering) | limited (HPH defaults) — **test your streaming** |
| Moving parts | more | fewer / simpler |

**Trade-off to know:** MCP Streamable HTTP can hold long-lived (SSE) responses.
HPH gives less control over buffering/timeouts than ARR. For typical
request/response tool calls it's great; if you rely on heavy long streams,
validate carefully (or use `../deploy`).

---

## Contents

| Path | Purpose |
|------|---------|
| `precheck.bat` | **Verify** all prerequisites; with `--install`, also install them from the bundle, then re-verify. |
| `deploy.bat` | Full end-to-end HPH deployment from this folder. |
| `run-tests.bat` | Run the unit tests (self-contained; no Pester/internet). |
| `config/deploy.settings.ps1` | **Edit this** — hostname, DB, app-pool identity, paths. |
| `templates/run_http.py` | HTTP entry point copied to the project root at deploy. |
| `templates/web.config.reference` | Reference of the generated HPH web.config. |
| `lib/DeployHph.psm1` | All core logic (unit-tested). |
| `lib/drivers/*.ps1` | Thin PowerShell drivers the `.bat` files call. |
| `tests/*.ps1` | Test harness + 50 unit tests. |

---

## Deploy on IIS — step by step

Do everything from an **elevated** (Administrator) `cmd` prompt on the target VM.

### 1. Enable IIS (Windows feature — not in the bundle)
```powershell
Install-WindowsFeature -Name Web-Server,Web-Common-Http,Web-WebSockets,`
  Web-Windows-Auth,Web-Mgmt-Console -IncludeManagementTools
```
`Web-WebSockets` matters for MCP streaming; `Web-Windows-Auth` only if you'll use
AD authentication.

### 2. Edit your settings
```bat
cd <project-root>\deploy_hph
notepad config\deploy.settings.ps1
```
Set at least `Hostname`, the `Db*` values, and (optionally) `AppPoolIdentity`.

**Hosting mode** — two choices via `IisMode`:

| `IisMode` | Result | Public URL |
|-----------|--------|-----------|
| `site` (default) | Standalone IIS site on port 80 with host header `Hostname` | `http://<Hostname>/mcp` |
| `application` | App nested under `ParentSite` (e.g. `Default Web Site`) as alias `AppAlias` | `http(s)://<Hostname>/<AppAlias>` |

In **application** mode the public path is `/<AppAlias>` and `McpPath` is **auto-derived** to `/<AppAlias>` (HttpPlatformHandler forwards the full path to Python, so the ASGI streamable path must match). To serve at `https://sitgis.jioconnect.com/mcp` under Default Web Site:

```powershell
IisMode        = 'application'
ParentSite     = 'Default Web Site'
AppAlias       = 'mcp'
Hostname       = 'sitgis.jioconnect.com'
EnableHttps    = 'true'
CertThumbprint = '<thumbprint of a cert already in LocalMachine\My>'
```

`EnableHttps='true'` adds an SNI https binding (`HttpsPort`, default 443) on the parent site and attaches the cert. The cert must already be imported into `LocalMachine\My`; DNS for `Hostname` must resolve to the server.

### 3. Prepare the offline bundle
Put these in `<project-root>\apps-py-iis` (or set `BundleDir`):
- `python-*.exe` (3.10+ 64-bit)
- `httpplatformhandler*.msi`  ← the HPH module
- `VC_redist.x64.exe` (if needed)
- any `*.whl` wheels for offline pip (asyncpg, mcp, python-dotenv, uvicorn, starlette, deps)

### 4. Check + install prerequisites
```bat
precheck.bat                        REM verify only (read-only)
precheck.bat --install --dry-run    REM preview what would be installed
precheck.bat --install              REM install silently, then re-verify
```
This installs each bundle item **one by one, silently** (VC redist → Python →
HttpPlatformHandler), then re-runs the full check.

### 5. Deploy
```bat
deploy.bat --dry-run                REM preview the 10-step plan, change NOTHING
deploy.bat                          REM perform the deployment
```

### 6. Add HTTPS + DNS + auth (manual, environment-specific)
- DNS A record for `Hostname` → server IP.
- TLS cert in **Local Computer → Personal**; add an **https/443** binding to the
  `mcp` site in IIS Manager.
- Optional auth: disable Anonymous + enable Windows Authentication on the site
  (see [../docs/DEPLOYMENT_IIS_WINDOWS_SERVER.md](../docs/DEPLOYMENT_IIS_WINDOWS_SERVER.md) §8, §10).

### 7. Verify
```powershell
Get-Website mcp
curl.exe -i https://<Hostname>/mcp   # 400/405/406 = endpoint live & speaking MCP
Get-Content <project-root>\app\logs\httpplatform.log -Tail 20
Get-Content <project-root>\app\logs\mcp-server.log -Tail 20
```

---

## What `deploy.bat` does (10 ordered steps)

A real run first runs the prerequisite check and **aborts if anything required
is missing**. Then:

| # | Step | Action |
|---|------|--------|
| 01 | `copy-run-http` | Copy `templates/run_http.py` → project root |
| 02 | `create-venv` | `python -m venv .venv` |
| 03 | `pip-install` | `requirements.txt` + `uvicorn[standard]` + `starlette` (offline via `--find-links <bundle>`) |
| 04 | `write-env` | Write `app\.env` from settings |
| 05 | `smoke-test` | Start `run_http.py` standalone on loopback, confirm it boots |
| 06 | `iis-apppool` | Create app pool (No Managed Code, AlwaysRunning; identity if set) |
| 07 | `iis-site` | Create the IIS site pointing at the **app directory** |
| 08 | `web-config` | Write the **HttpPlatformHandler** `web.config` into the app directory |
| 09 | `firewall` | Add inbound firewall rules (80/443) |
| 10 | `start-site` | Start the app pool + site (first request launches Python) |

The generated `web.config` sets `processPath` to the venv `python.exe`,
`arguments="run_http.py"`, and `MCP_PORT=%HTTP_PLATFORM_PORT%` — so IIS assigns a
private port and `run_http.py` binds to it on `127.0.0.1`.

---

## Development / TDD

```bat
run-tests.bat
```
Logic lives in `lib/DeployHph.psm1`, covered by 50 dependency-free unit tests
(`tests/`) that never touch IIS/network/installers. Follow **Red → Green →
Refactor**: add a failing test in `tests/DeployHph.Tests.ps1`, then implement.

---

## Notes & safety

- All `.bat` files use CRLF line endings (required by `cmd.exe`).
- `--install` and real deploys require Administrator (dry-runs do not).
- The Python process binds `127.0.0.1` only; **IIS is the sole public entry**.
  Do not open the app port externally.
- Set `DbPassword` (and lock down NTFS on `app\.env`) before a real deploy.
- HttpPlatformHandler is a **separate IIS module** — it must be installed
  (bundle `httpplatformhandler*.msi`) before deploy; `precheck.bat` verifies it.
