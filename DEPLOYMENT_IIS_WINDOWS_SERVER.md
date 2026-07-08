# Deployment Guide — GIS PostgreSQL MCP Server on Windows Server with IIS

This guide deploys the MCP server on a **Windows Server**, front-ended by **IIS** as the web
server / reverse proxy, and made reachable over a **domain name with HTTPS** so you can access it
across the network.

> **Read this first — the transport gap.**
> The server as shipped runs on the MCP **stdio** transport (`mcp.run(transport="stdio")` in
> [app/server.py](../app/server.py)). stdio servers talk over a child process's stdin/stdout and are
> **not** HTTP endpoints, so IIS cannot host them directly. To put it behind IIS on a domain, the
> server must run with the MCP **Streamable HTTP** transport and IIS must reverse-proxy to it.
>
> Per the constraint that **no existing file may be modified**, this is achieved by adding **one new,
> separate entry-point script** at the project root (`run_http.py`, provided in
> [§5](#5-add-the-http-entry-point-new-file-only)). The existing `app/` code is reused unchanged.

---

## Table of contents
1. [Deployment architecture](#1-deployment-architecture)
2. [Prerequisites (complete checklist)](#2-prerequisites-complete-checklist)
3. [Install the base software](#3-install-the-base-software)
4. [Prepare the application](#4-prepare-the-application)
5. [Add the HTTP entry point (new file only)](#5-add-the-http-entry-point-new-file-only)
6. [Run the app as a Windows Service (NSSM)](#6-run-the-app-as-a-windows-service-nssm)
7. [Configure IIS as a reverse proxy](#7-configure-iis-as-a-reverse-proxy)
8. [DNS, domain name, and TLS certificate](#8-dns-domain-name-and-tls-certificate)
9. [Firewall and network](#9-firewall-and-network)
10. [Restrict access to your domain (authentication)](#10-restrict-access-to-your-domain-authentication)
11. [Verify the deployment](#11-verify-the-deployment)
12. [Connect a client](#12-connect-a-client)
13. [Security hardening checklist](#13-security-hardening-checklist)
14. [Operations: logs, updates, backups](#14-operations-logs-updates-backups)
15. [Troubleshooting](#15-troubleshooting)
16. [Appendix A — Alternative: HttpPlatformHandler](#appendix-a--alternative-httpplatformhandler)
17. [Appendix B — Quick command reference](#appendix-b--quick-command-reference)

---

## 1. Deployment architecture

The recommended pattern is **IIS as a reverse proxy** in front of a local Python (uvicorn) process
that is kept alive by a **Windows Service**.

```
                    Internet / Corporate LAN
                              │
                    https://mcp.yourdomain.com   (TLS 443)
                              │
                              ▼
             ┌─────────────────────────────────────┐
             │            Windows Server            │
             │                                      │
             │   ┌──────────────┐                   │
             │   │     IIS      │  Reverse proxy    │
             │   │  (ARR + URL  │  (URL Rewrite)    │
             │   │   Rewrite)   │  TLS termination  │
             │   │              │  Windows Auth     │
             │   └──────┬───────┘                   │
             │          │  http://127.0.0.1:8000/mcp│
             │          ▼                           │
             │   ┌──────────────┐                   │
             │   │ Python app   │  MCP Streamable   │
             │   │ (uvicorn)    │  HTTP transport   │
             │   │ Windows Svc  │  (run_http.py)    │
             │   └──────┬───────┘                   │
             └──────────┼───────────────────────────┘
                        │ asyncpg (5432)
                        ▼
                ┌───────────────┐
                │  PostgreSQL   │
                └───────────────┘
```

**Why this pattern:**
- IIS handles TLS, the public domain name, logging, and (optionally) Windows/AD authentication.
- The Python process only listens on `127.0.0.1` (loopback) — it is never exposed directly.
- A Windows Service gives auto-start on boot, crash-restart, and a managed service account.

An alternative that lets **IIS launch and manage the Python process itself** (via
`HttpPlatformHandler`) is documented in [Appendix A](#appendix-a--alternative-httpplatformhandler).

---

## 2. Prerequisites (complete checklist)

### 2.1 Server & OS
- [ ] **Windows Server 2019 or 2022** (Standard or Datacenter), fully patched.
- [ ] Local administrator rights on the server.
- [ ] The server is **joined to your Active Directory domain** (required for domain-name access and
      optional Windows authentication).

### 2.2 Software to install (details in §3)
- [ ] **IIS** (Web Server role) with: *Web Server > Common HTTP Features*, *Application Development
      (WebSocket Protocol)*, *Security > Windows Authentication* (optional), *Management Tools
      (IIS Management Console)*.
- [ ] **URL Rewrite 2.1** (IIS extension).
- [ ] **Application Request Routing (ARR) 3.0** (IIS extension — provides the reverse-proxy engine).
- [ ] **Python 3.10 or newer** (64-bit) — the code uses `X | None` typing and requires the `mcp`
      package.
- [ ] **uvicorn** (ASGI server) and **starlette** — installed via pip (see §4).
- [ ] **NSSM** (Non-Sucking Service Manager) — to run Python as a Windows Service (§6).
      *(Alternative: `sc.exe`/Task Scheduler, or HttpPlatformHandler in Appendix A.)*

### 2.3 Database
- [ ] A reachable **PostgreSQL** instance (host, port, database name).
- [ ] A **dedicated, read-only** PostgreSQL login for the app (see [§13](#13-security-hardening-checklist)).
- [ ] Network path from the Windows Server to PostgreSQL on port `5432` (firewall allows it).

### 2.4 Domain / DNS / TLS
- [ ] A **DNS record** (A or CNAME), e.g. `mcp.yourdomain.com`, pointing to the server's IP.
      In an AD environment this is usually an A record in your internal DNS zone.
- [ ] A **TLS certificate** for that hostname — from your **internal AD Certificate Services CA**
      (typical for `*.corp`/internal domains) or a public CA. You need the certificate installed in
      the server's **Local Computer > Personal** store.

### 2.5 Accounts & access
- [ ] A **domain service account** (e.g. `DOMAIN\svc-mcp`) to run the Windows Service, with a
      non-expiring, vaulted password and **least privilege** (log on as a service; read access to the
      app folder; network access to PostgreSQL).
- [ ] The list of **domain users/groups** who should be allowed to reach the endpoint (for §10).

### 2.6 Information to have ready
| Item | Example |
|------|---------|
| Public hostname | `mcp.yourdomain.com` |
| Local app port | `8000` |
| MCP path | `/mcp` |
| PostgreSQL host/port | `db01.corp.local:5432` |
| PostgreSQL database | `gis` |
| Read-only DB user | `mcp_readonly` |
| Install path | `C:\apps\mcp-server` |
| Service account | `DOMAIN\svc-mcp` |

---

## 3. Install the base software

Run PowerShell **as Administrator**.

### 3.1 Install IIS with required features
```powershell
Install-WindowsFeature -Name Web-Server,Web-Common-Http,Web-WebSockets,`
  Web-Windows-Auth,Web-Mgmt-Console,Web-Http-Logging,Web-Http-Redirect `
  -IncludeManagementTools
```
- `Web-WebSockets` is required because MCP Streamable HTTP / SSE can use long-lived connections.
- `Web-Windows-Auth` is only needed if you will use Windows/AD authentication (§10).

### 3.2 Install URL Rewrite and ARR
Download and install (in this order), or use the Web Platform Installer / winget/choco if available:
- **URL Rewrite 2.1** — <https://www.iis.net/downloads/microsoft/url-rewrite>
- **Application Request Routing 3.0** — <https://www.iis.net/downloads/microsoft/application-request-routing>

After installing ARR, **enable proxy** at the server level:
1. Open **IIS Manager** → click the **server node** (top level).
2. Open **Application Request Routing Cache** → **Server Proxy Settings** (right pane).
3. Tick **Enable proxy** → **Apply**.

(You can also enable it via `appcmd`; see [Appendix B](#appendix-b--quick-command-reference).)

### 3.3 Install Python
- Download Python 3.10+ (64-bit) from <https://www.python.org/downloads/windows/>.
- During install: tick **"Add python.exe to PATH"** and **"Install for all users"**.
- Verify:
```powershell
python --version    # expect 3.10 or higher
```

### 3.4 Install NSSM
- Download from <https://nssm.cc/download>, extract, and copy `win64\nssm.exe` to e.g.
  `C:\tools\nssm\nssm.exe`. (Or `choco install nssm` if Chocolatey is present.)

---

## 4. Prepare the application

### 4.1 Copy the code
Copy the project to a stable path, e.g. `C:\apps\mcp-server`, so the structure is:
```
C:\apps\mcp-server\
├── app\...
├── requirements.txt
├── run_http.py        ← you will create this in §5
└── docs\...
```

### 4.2 Create a virtual environment and install dependencies
```powershell
cd C:\apps\mcp-server
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
# HTTP transport dependencies (not needed for stdio, required for IIS deployment):
pip install "uvicorn[standard]" starlette
```
> `mcp` (FastMCP) already depends on Starlette, but installing it explicitly keeps the deployment
> self-documenting. `uvicorn[standard]` adds the production ASGI server + websockets support.

### 4.3 Create the runtime configuration
Create **`C:\apps\mcp-server\app\.env`** (this is where `app/config.py` reads it from):
```env
DB_HOST=db01.corp.local
DB_PORT=5432
DB_NAME=gis
DB_USER=mcp_readonly
DB_PASSWORD=<strong-password>
DB_SCHEMA=public

AUTO_SETUP_ALL_TABLES=false
NE_SCHEMA=
NE_TABLE_PREFIX=ne
AUTO_SETUP_NE_TABLES=true
```
- Restrict NTFS permissions on this file to the service account + Administrators only (§13).
- If the read-only DB user cannot `CREATE FUNCTION`, keep `AUTO_SETUP_*` as `false` and use the
  discovery + `execute_read_query` tools, **or** have a DBA pre-create the functions. See §13.

---

## 5. Add the HTTP entry point (new file only)

Create a **new** file `C:\apps\mcp-server\run_http.py`. This is the *only* new code required, and it
**does not modify any existing file** — it imports the already-built `mcp` object and serves it over
HTTP.

```python
# run_http.py — HTTP entry point for hosting the MCP server behind IIS.
# Reuses the existing FastMCP app from app/server.py (no source files modified).
import os

from app.server import mcp

# Bind to loopback only; IIS (reverse proxy) is the sole public entry point.
mcp.settings.host = os.getenv("MCP_HOST", "127.0.0.1")
mcp.settings.port = int(os.getenv("MCP_PORT", "8000"))
# Streamable HTTP is served at this path (final URL: http://host:port/mcp).
mcp.settings.streamable_http_path = os.getenv("MCP_PATH", "/mcp")

if __name__ == "__main__":
    # Streamable HTTP is the current MCP HTTP transport.
    mcp.run(transport="streamable-http")
```

> **Notes**
> - `mcp` is created in [app/server.py](../app/server.py) as `FastMCP("postgres-mcp-server", ...)`;
>   importing it also registers all 20 tools (the `@mcp.tool()` decorators run on import).
> - FastMCP exposes `settings.host`, `settings.port`, and `settings.streamable_http_path`. If your
>   installed `mcp` version differs, set the equivalent settings or pass them when constructing
>   FastMCP — but do that in this new file, not in `app/server.py`.
> - Keep the host on `127.0.0.1`; only IIS should be reachable from the network.

### Smoke-test it manually (before making it a service)
```powershell
cd C:\apps\mcp-server
.\.venv\Scripts\Activate.ps1
python run_http.py
```
You should see uvicorn start on `127.0.0.1:8000`. Leave it running and, in a second terminal:
```powershell
# Expect an HTTP response (405/406/400 is fine — it proves the endpoint is live and speaking MCP).
curl.exe -i http://127.0.0.1:8000/mcp
```
Stop it with `Ctrl+C` once confirmed. Check `app\logs\mcp-server.log` for the DB connection line.

---

## 6. Run the app as a Windows Service (NSSM)

Install the service so the Python process starts on boot and restarts on failure.

```powershell
$nssm = "C:\tools\nssm\nssm.exe"
$app  = "C:\apps\mcp-server"

& $nssm install McpServer "$app\.venv\Scripts\python.exe" "run_http.py"
& $nssm set McpServer AppDirectory $app
& $nssm set McpServer AppStdout "$app\app\logs\service-stdout.log"
& $nssm set McpServer AppStderr "$app\app\logs\service-stderr.log"
& $nssm set McpServer Start SERVICE_AUTO_START
& $nssm set McpServer AppEnvironmentExtra "MCP_HOST=127.0.0.1" "MCP_PORT=8000" "MCP_PATH=/mcp"

# Run under the domain service account (least privilege):
& $nssm set McpServer ObjectName "DOMAIN\svc-mcp" "P@ssword-from-vault"

Start-Service McpServer
Get-Service McpServer
```
- Grant `DOMAIN\svc-mcp` the **"Log on as a service"** right (NSSM usually sets this; verify via
  `secpol.msc` → Local Policies → User Rights Assignment).
- Confirm the service is `Running` and that `app\logs\mcp-server.log` shows
  *"PostgreSQL connection pool ready"*.

> To later update the port/path, use `nssm set McpServer AppEnvironmentExtra ...` and
> `Restart-Service McpServer`.

---

## 7. Configure IIS as a reverse proxy

### 7.1 Create the site
1. In **IIS Manager**, right-click **Sites** → **Add Website**.
   - **Site name:** `mcp`
   - **Physical path:** `C:\inetpub\mcp` (create an empty folder; content is served by the proxy, not
     from disk).
   - **Binding:** start with **http**, host name `mcp.yourdomain.com`, port `80` (you will add HTTPS
     in §8).
2. Create the physical folder:
   ```powershell
   New-Item -ItemType Directory -Force C:\inetpub\mcp | Out-Null
   ```

### 7.2 Add the reverse-proxy rule (web.config)
Place this `web.config` in `C:\inetpub\mcp\web.config`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <!-- Forward everything to the local MCP process -->
        <rule name="ReverseProxyToMcp" stopProcessing="true">
          <match url="(.*)" />
          <action type="Rewrite" url="http://127.0.0.1:8000/{R:1}" />
        </rule>
      </rules>
      <outboundRules>
        <!-- Preserve correct scheme/host for any Location headers the app returns -->
        <preConditions>
          <preCondition name="IsRedirect">
            <add input="{RESPONSE_STATUS}" pattern="3\d\d" />
          </preCondition>
        </preConditions>
      </outboundRules>
    </rewrite>
    <!-- MCP Streamable HTTP / SSE need buffering off and generous timeouts -->
    <proxy xmlns="http://schemas.microsoft.com/iis/application-request-routing/config"
           preserveHostHeader="true" />
    <httpProtocol>
      <customHeaders>
        <!-- Optional: identify the proxy -->
        <add name="X-Proxied-By" value="IIS-ARR" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
```

> **Server Proxy must be enabled** (§3.2) for the `Rewrite` to `http://…` to work. If you see
> `404.4` or the rule is ignored, proxy is not enabled.

### 7.3 Tune ARR for long-lived MCP connections
Streamable HTTP can hold connections open (server-sent events). Increase the ARR proxy timeout:

1. IIS Manager → **server node** → **Application Request Routing Cache** → **Server Proxy Settings**.
2. Set **Time-out (seconds)** to e.g. `300` (or higher for very long streams).
3. Ensure **Enable proxy** is ticked → **Apply**.

Also disable response buffering so streamed events flow through (this is on by default off in ARR for
proxied responses; if you observe buffering, set `responseBufferLimit=0` on the handler, or add to the
site `web.config` under `<serverRuntime>` / ARR settings as needed).

### 7.4 (If not using a path prefix) confirm the endpoint
With the rule above, external `https://mcp.yourdomain.com/mcp` maps to
`http://127.0.0.1:8000/mcp`. Good — that matches `MCP_PATH=/mcp`.

---

## 8. DNS, domain name, and TLS certificate

### 8.1 DNS
- Create an **A record** `mcp` in your `yourdomain.com` (or internal `corp.local`) zone pointing to
  the server's IP. Confirm:
  ```powershell
  Resolve-DnsName mcp.yourdomain.com
  ```

### 8.2 Obtain and install the certificate
**Option A — Internal AD CS (typical for domain/internal names):**
1. Request a **Web Server** certificate for `mcp.yourdomain.com` from your enterprise CA
   (via `certlm.msc` → Personal → *All Tasks* → *Request New Certificate*, or `certreq`).
2. Ensure it lands in **Local Computer → Personal → Certificates**.

**Option B — Public CA:** obtain a certificate for the public hostname and import the PFX into
**Local Computer → Personal**.

### 8.3 Add the HTTPS binding
1. IIS Manager → site `mcp` → **Bindings** → **Add** →
   - **Type:** `https`, **Port:** `443`, **Host name:** `mcp.yourdomain.com`
   - **SSL certificate:** select the one from §8.2. → **OK**.
2. **Require HTTPS / redirect HTTP→HTTPS:** with URL Rewrite installed, add a redirect rule, or use
   the site's **SSL Settings → Require SSL** plus an HTTP→HTTPS rewrite rule:
   ```xml
   <rule name="HttpToHttps" stopProcessing="true">
     <match url="(.*)" />
     <conditions><add input="{HTTPS}" pattern="off" /></conditions>
     <action type="Redirect" url="https://{HTTP_HOST}/{R:1}" redirectType="Permanent" />
   </rule>
   ```
   Put this rule **before** the reverse-proxy rule in `web.config`.

### 8.4 (Optional) HSTS
Once HTTPS is confirmed working, add HSTS via a custom response header
(`Strict-Transport-Security: max-age=31536000; includeSubDomains`).

---

## 9. Firewall and network

```powershell
# Allow inbound HTTPS (and HTTP if you keep the redirect) to IIS
New-NetFirewallRule -DisplayName "IIS HTTPS" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow
New-NetFirewallRule -DisplayName "IIS HTTP"  -Direction Inbound -Protocol TCP -LocalPort 80  -Action Allow
```
- **Do not** open port `8000` on the external firewall — the Python process must stay private on
  loopback.
- Ensure the server can reach **PostgreSQL on 5432** (outbound), and that the PostgreSQL host's
  firewall / `pg_hba.conf` permits the Windows Server's IP with the `mcp_readonly` user.

---

## 10. Restrict access to your domain (authentication)

You said you will access it over the domain. Because MCP has no built-in user login here, put access
control at IIS. Choose one:

### Option 1 — Windows Authentication (AD-integrated, recommended for internal use)
1. IIS Manager → site `mcp` → **Authentication**:
   - **Disable** Anonymous Authentication.
   - **Enable** Windows Authentication.
2. Restrict to a specific AD group via **Authorization Rules** (URL Authorization):
   ```xml
   <system.webServer>
     <security>
       <authentication>
         <anonymousAuthentication enabled="false" />
         <windowsAuthentication enabled="true" />
       </authentication>
       <authorization>
         <remove users="*" roles="" verbs="" />
         <add accessType="Allow" roles="DOMAIN\MCP-Users" />
       </authorization>
     </security>
   </system.webServer>
   ```
   > Only members of `DOMAIN\MCP-Users` can reach the endpoint. **Note:** the MCP client you use must
   > be capable of Negotiate/NTLM auth. If your client cannot do Windows auth, use Option 2 or 3.

### Option 2 — IP allow-list
Restrict to known subnets via **IP Address and Domain Restrictions** (install
`Web-IP-Security` feature), allowing only your office/VPN ranges.

### Option 3 — Client-certificate (mutual TLS)
Require client certificates on the HTTPS binding (SSL Settings → **Require** + **Client certificates:
Require**). Strong, but every client needs an issued certificate.

> **Combine** an IP allow-list with Windows auth for defence in depth on internal deployments.

---

## 11. Verify the deployment

Run these from a client machine that can resolve the domain:

```powershell
# 1) DNS resolves to the server
Resolve-DnsName mcp.yourdomain.com

# 2) TLS handshake + endpoint reachable through IIS (auth may prompt/deny — that's expected)
curl.exe -i https://mcp.yourdomain.com/mcp

# 3) With Windows auth enabled, pass current credentials:
curl.exe -i --negotiate -u : https://mcp.yourdomain.com/mcp
```
Success indicators:
- TLS negotiates with **no certificate warning** (trusted CA chain).
- You get an HTTP status from the MCP app (e.g. `400/405/406` for a bare GET, or a proper MCP
  response for a valid MCP request) — **not** an IIS `502.3`/`404.4`/`500`.
- `app\logs\mcp-server.log` shows tool activity when a real MCP client connects.

Server-side checks:
```powershell
Get-Service McpServer                 # Running
Test-NetConnection 127.0.0.1 -Port 8000   # TcpTestSucceeded : True
Get-Content C:\apps\mcp-server\app\logs\mcp-server.log -Tail 20
```

---

## 12. Connect a client

Point any **MCP HTTP (Streamable HTTP) client** at:
```
https://mcp.yourdomain.com/mcp
```

**Claude Desktop (custom connector / remote MCP over HTTP):** add a remote MCP server entry with the
URL above. If you enabled Windows auth or client certs, the client/host must be able to satisfy that
challenge; for internal use, running the client on a domain-joined machine with Negotiate support is
simplest.

Example first prompts (same as stdio usage):
> "Run `setup_ne_tables` and show me a summary of all NE data."
> "Search all NE tables for 'Guwahati'."
> "List 20 records from `ne_buildings`."

---

## 13. Security hardening checklist

- [ ] **Read-only DB role.** Create a least-privilege PostgreSQL login:
  ```sql
  CREATE ROLE mcp_readonly LOGIN PASSWORD '<strong>';
  GRANT CONNECT ON DATABASE gis TO mcp_readonly;
  GRANT USAGE ON SCHEMA public TO mcp_readonly;
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO mcp_readonly;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO mcp_readonly;
  ```
  - If you want the app's `setup_*` auto-generation of functions, additionally grant
    `GRANT CREATE ON SCHEMA public TO mcp_readonly;` **or** have a DBA pre-create the `mcp_*`
    functions and skip auto-setup. Prefer *not* granting `CREATE` in production — pre-create the
    functions instead.
- [ ] **Loopback binding.** Confirm the Python process listens only on `127.0.0.1` (§5/§6). Port 8000
      must not be firewall-open externally.
- [ ] **TLS only.** Force HTTPS; disable weak protocols/ciphers on the server (schannel hardening).
- [ ] **Authentication at IIS.** Enable Windows auth / IP allow-list / mTLS (§10).
- [ ] **Secrets.** Lock down NTFS on `app\.env`:
  ```powershell
  icacls C:\apps\mcp-server\app\.env /inheritance:r
  icacls C:\apps\mcp-server\app\.env /grant "DOMAIN\svc-mcp:(R)" "BUILTIN\Administrators:(F)"
  ```
- [ ] **Least-privilege service account.** `DOMAIN\svc-mcp` has only *log on as a service* + read
      access to the app + network to PostgreSQL.
- [ ] **`execute_read_query` awareness.** The app-layer filter blocks non-`SELECT` and a keyword list,
      but it is not a full parser — the read-only DB role is the real guardrail. Consider whether to
      expose this tool at all in your environment.
- [ ] **Patching.** Keep Windows, IIS, Python, and pip dependencies updated.
- [ ] **Logging/monitoring.** Ship IIS logs + `mcp-server.log` to your SIEM; alert on the service
      stopping.

---

## 14. Operations: logs, updates, backups

| Task | How |
|------|-----|
| App logs | `C:\apps\mcp-server\app\logs\mcp-server.log` (rotate with a scheduled task or logrotate-equivalent). |
| Service stdout/stderr | `service-stdout.log` / `service-stderr.log` (set in §6). |
| IIS access logs | `C:\inetpub\logs\LogFiles\` (per-site). |
| Restart app | `Restart-Service McpServer` |
| Update code | Deploy new files → `pip install -r requirements.txt` in the venv → `Restart-Service McpServer`. |
| Update config | Edit `app\.env` (or NSSM env) → `Restart-Service McpServer`. |
| Rollback | Keep the previous folder version; repoint the service `AppDirectory` and restart. |
| Backup | Back up `app\.env`, `web.config`, the IIS site config, and NSSM service settings. Database is backed up separately by the DBA. |

---

## 15. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| IIS `502.3` bad gateway | Python process down or wrong port | `Get-Service McpServer`; `Test-NetConnection 127.0.0.1 -Port 8000`; check service logs. |
| IIS `404.4` / rewrite ignored | ARR **proxy not enabled** | §3.2 — tick *Enable proxy* in Server Proxy Settings. |
| `500.19` on site start | `web.config` invalid, or URL Rewrite/ARR not installed | Install URL Rewrite + ARR; validate XML. |
| Certificate warning in client | Cert not trusted / wrong hostname | Use a cert whose CN/SAN = `mcp.yourdomain.com`, issued by a CA the client trusts. |
| Streaming/SSE cuts off | ARR timeout too low / buffering | Raise ARR **Time-out** (§7.3); ensure WebSockets feature installed. |
| `401` for everyone | Windows auth on, client can't negotiate | Test with `curl --negotiate -u :` from a domain machine, or relax to IP allow-list. |
| DB connection fails in log | Wrong `app\.env`, firewall, or `pg_hba.conf` | Verify creds; `Test-NetConnection <db> -Port 5432`; check PostgreSQL host rules. |
| Tools say "no tables registered" | Auto-setup off / no CREATE privilege | Call `setup_all_tables`/`setup_ne_tables`, or set `AUTO_SETUP_*=true`, or pre-create functions. |
| `mcp.settings.*` attribute error | Different `mcp` package version | Set the equivalent FastMCP settings/args in `run_http.py` for your installed version. |

---

## Appendix A — Alternative: HttpPlatformHandler

If you prefer **IIS to launch and manage the Python process** (no separate Windows Service):

1. Install the **HttpPlatformHandler** module for IIS
   (<https://www.iis.net/downloads/microsoft/httpplatformhandler>).
2. Use this `web.config` in the site's physical folder. IIS assigns a private port via
   `%HTTP_PLATFORM_PORT%`; the app must bind to it.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="httpPlatformHandler" path="*" verb="*"
           modules="httpPlatformHandler" resourceType="Unspecified" />
    </handlers>
    <httpPlatform stdoutLogEnabled="true"
                  stdoutLogFile=".\app\logs\httpplatform.log"
                  startupTimeLimit="60"
                  processPath="C:\apps\mcp-server\.venv\Scripts\python.exe"
                  arguments="run_http.py">
      <environmentVariables>
        <environmentVariable name="MCP_HOST" value="127.0.0.1" />
        <environmentVariable name="MCP_PORT" value="%HTTP_PLATFORM_PORT%" />
        <environmentVariable name="MCP_PATH" value="/mcp" />
      </environmentVariables>
    </httpPlatform>
  </system.webServer>
</configuration>
```
- The `run_http.py` from §5 already reads `MCP_PORT` from the environment, so it honours
  `%HTTP_PLATFORM_PORT%` automatically.
- Set the site's **Application Pool** identity to your service account, or keep `ApplicationPoolIdentity`
  and grant it DB/file access accordingly.
- **Trade-off:** simpler process management, but no ARR-style proxy tuning; long-lived streaming
  behaviour depends on HttpPlatformHandler defaults. For heavy streaming, the NSSM + ARR pattern
  (main guide) gives more control.

---

## Appendix B — Quick command reference

```powershell
# Enable ARR proxy from the command line (alternative to the GUI)
Import-Module WebAdministration
Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
  -Filter "system.webServer/proxy" -Name "enabled" -Value "True"

# Service lifecycle
Start-Service McpServer ; Restart-Service McpServer ; Stop-Service McpServer
Get-Service McpServer

# Health checks
Test-NetConnection 127.0.0.1 -Port 8000
curl.exe -i http://127.0.0.1:8000/mcp
curl.exe -i https://mcp.yourdomain.com/mcp

# Tail logs
Get-Content C:\apps\mcp-server\app\logs\mcp-server.log -Tail 30 -Wait
```

---

### Deployment summary (what you built)
- IIS site on `mcp.yourdomain.com` (HTTPS, trusted cert, optional Windows auth).
- Reverse-proxy (ARR + URL Rewrite) → `http://127.0.0.1:8000/mcp`.
- Python MCP server (Streamable HTTP via `run_http.py`) kept alive by the `McpServer` Windows Service
  under `DOMAIN\svc-mcp`.
- Read-only PostgreSQL access via `mcp_readonly`.
- No existing application source file was modified; only `run_http.py`, `web.config`, and `app/.env`
  were added.
