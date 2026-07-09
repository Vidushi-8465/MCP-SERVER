That actually puts you in a much better position because you'll understand the complete deployment process instead of just running a script.

Since **you're starting from scratch**, I'll explain it exactly as if you're the DevOps engineer deploying a new Python application on a fresh Windows Server.

---

# Complete End-to-End Deployment Workflow

```
Develop Project
        │
        ▼
Push to Git
        │
        ▼
Login to Windows Server (LEPIM)
        │
        ▼
Install Prerequisites
        │
        ▼
Clone Repository
        │
        ▼
Setup Python Environment
        │
        ▼
Configure Environment Variables
        │
        ▼
Run Project Locally
        │
        ▼
Create Windows Service
        │
        ▼
Configure IIS
        │
        ▼
Configure Reverse Proxy
        │
        ▼
Configure HTTPS
        │
        ▼
Test Deployment
        │
        ▼
Production Ready
```

---

# PHASE 1 — Windows Server Setup

Login using LEPIM.

The first thing to check is whether the server is ready.

### 1. Check Python

```powershell
python --version
```

If Python is not installed, install it.

---

### 2. Check pip

```powershell
pip --version
```

---

### 3. Check Git

```powershell
git --version
```

If Git isn't installed, either install it or copy the project as a ZIP.

---

### 4. Open IIS

Search

```
IIS Manager
```

You should see

```
Server

Application Pools

Sites
```

---

### 5. Check IIS Features

Verify these are installed:

* URL Rewrite
* ARR (Application Request Routing)

If not, install them.

---

# PHASE 2 — Create Project Folder

Suppose your company stores applications here:

```
C:\apps
```

Create

```
C:\apps
```

Then

```
C:\apps\MCP-SERVER
```

Result

```
C:

└── apps

      └── MCP-SERVER
```

---

# PHASE 3 — Clone Repository

```powershell
cd C:\apps

git clone https://github.com/company/mcp-server.git
```

Now

```
C:\apps\MCP-SERVER
```

contains

```
app/

requirements.txt

README.md

...
```

---

# PHASE 4 — Virtual Environment

Inside project

```powershell
cd C:\apps\MCP-SERVER
```

Create

```powershell
python -m venv .venv
```

Activate

```powershell
.\.venv\Scripts\activate
```

---

# PHASE 5 — Install Dependencies

Upgrade pip

```powershell
python -m pip install --upgrade pip
```

Install

```powershell
pip install -r requirements.txt
```

Then

```powershell
pip install uvicorn[standard] starlette
```

---

# PHASE 6 — Create Environment File

Create

```
app\.env
```

Example

```
DB_HOST=

DB_PORT=

DB_NAME=

DB_USER=

DB_PASSWORD=

DB_SCHEMA=
```

Ask DBA for these.

---

# PHASE 7 — Convert stdio to HTTP

Originally

```
Claude

↓

stdio

↓

Python
```

We need

```
IIS

↓

HTTP

↓

Python
```

Create

```
run_http.py
```

This imports

```python
from app.server import mcp
```

and starts

```python
mcp.run(
    transport="streamable-http"
)
```

Exactly as described in the deployment guide. 

---

# PHASE 8 — Local Testing

Run

```powershell
python run_http.py
```

Expected

```
127.0.0.1:8000
```

Open

```
http://127.0.0.1:8000/mcp
```

If you get

```
400

405

406
```

Good.

Server is alive.

---

# PHASE 9 — Create Windows Service

Don't run

```
python run_http.py
```

manually forever.

Create

```
Windows Service

↓

McpServer
```

This makes

```
Server Boot

↓

Service Starts

↓

Python Starts
```

The deployment guide uses NSSM for this. 

---

# PHASE 10 — IIS Folder

Python project stays here

```
C:\apps\MCP-SERVER
```

IIS folder is different.

Create

```
C:\inetpub\mcp
```

Inside

```
web.config
```

Nothing else.

---

# PHASE 11 — Create IIS Website

Open

```
Sites
```

↓

Right Click

```
Add Website
```

Fill

Site Name

```
MCP
```

Physical Path

```
C:\inetpub\mcp
```

Binding

```
HTTP
```

Port

```
80
```

Hostname

```
mcp.company.com
```

---

# PHASE 12 — Reverse Proxy

Enable

```
Application Request Routing
```

↓

Enable Proxy

Then

```
URL Rewrite
```

Your rule becomes

```
Incoming Request

↓

IIS

↓

127.0.0.1:8000

↓

run_http.py
```

---

# PHASE 13 — HTTPS

Company certificate

↓

Bind

```
443
```

Now

```
https://mcp.company.com/mcp
```

works.

---

# PHASE 14 — Windows Firewall

Allow

```
80

443
```

Don't expose

```
8000
```

because IIS should be the only public entry point. 

---

# PHASE 15 — Final Testing

Test

```
http://127.0.0.1:8000/mcp
```

↓

Test

```
http://localhost/mcp
```

↓

Test

```
https://mcp.company.com/mcp
```

↓

Connect

```
Claude Desktop

or

Cursor

or

another MCP client
```

---

# Overall Architecture

```
                Client
                  │
                  ▼
         https://mcp.company.com
                  │
                  ▼
           IIS Website (Port 443)
                  │
                  ▼
      URL Rewrite + ARR Reverse Proxy
                  │
                  ▼
      http://127.0.0.1:8000/mcp
                  │
                  ▼
          Python (run_http.py)
                  │
                  ▼
            FastMCP Application
                  │
                  ▼
            asyncpg Connection Pool
                  │
                  ▼
          PostgreSQL GIS Database
```

## I also recommend a practice run

Since this is your first IIS deployment, don't wait until you're on the company server. We can do a **local Windows simulation** on your own machine:

1. Install IIS on your Windows PC (if available).
2. Create `run_http.py`.
3. Create the IIS site.
4. Configure ARR and URL Rewrite.
5. Run the MCP server locally.
6. Verify that `http://localhost/mcp` works through IIS.

Once you've done it once locally, repeating the same process on the company server becomes much more straightforward.
