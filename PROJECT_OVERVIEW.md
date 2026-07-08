# Project Overview — GIS PostgreSQL MCP Server

## 1. What this project is

The **GIS PostgreSQL MCP Server** is a Python application that implements the
[**Model Context Protocol (MCP)**](https://modelcontextprotocol.io). MCP is an open standard that lets
AI assistants (for example **Claude Desktop**, or any MCP-compatible client) call structured, well-defined
"tools" exposed by a server.

This particular server sits **in front of a PostgreSQL database** and exposes it as a catalogue of
**read-only** tools. Instead of giving an AI raw, unrestricted SQL access, the server offers safe,
curated operations such as *"list tables"*, *"show me 100 rows from this table"*, *"search all
Network-Engineer tables for the word Guwahati"*, and *"run this SELECT query"*.

It is purpose-built for a **GIS (Geographic Information System)** workload with a special focus on
**NE (Network Engineer) regional data** — tables that describe network infrastructure such as
buildings, sites, and network elements (e.g. `ne_buildings`, `ne_sites`).

### In one sentence
> A read-only, tool-based gateway that lets an AI assistant safely explore and query a GIS / network
> PostgreSQL database through the Model Context Protocol.

### What it is **not**
- It is **not** a general web application or REST API for end users.
- It performs **no writes** — all tools are read-only by design (`INSERT`, `UPDATE`, `DELETE`, `DROP`,
  `ALTER`, `TRUNCATE` are explicitly blocked).
- It has **no built-in user interface** — the "UI" is the AI assistant / MCP client that connects to it.

---

## 2. Key capabilities

| Capability | Description |
|------------|-------------|
| **Table discovery** | Enumerate tables and inspect their columns, data types, and primary keys. |
| **Automatic setup** | Register tables and auto-generate PostgreSQL stored functions (`list`, `count`, `search`, `get_by_id`) per table. |
| **Generic read access** | Paginated listing, single-record fetch by primary key, text search, and row counts for any registered table. |
| **Custom queries** | Execute arbitrary **`SELECT`-only** SQL (joins, reports, analytics) with keyword guards. |
| **NE (Network Engineer) domain tools** | Auto-discover "NE" tables by schema/prefix/name patterns and provide dedicated tools, including a cross-table search over *all* NE tables at once. |
| **Read-only safety** | Only `SELECT` is allowed through the custom-query tool; generated stored functions are `STABLE` (non-mutating). |
| **File-based logging** | All activity is logged to a file (never to stdout), because stdio is reserved for MCP protocol traffic. |

---

## 3. The 20 tools

### Discovery & setup — general (6)
| Tool | Purpose |
|------|---------|
| `list_tables` | List all tables in the default schema. |
| `get_table_schema` | Columns, types, and primary key for a table. |
| `setup_all_tables` | Register every table and create its stored functions. |
| `setup_table` | Register a single table. |
| `list_registered_tables` | Show tables that are ready to use. |
| `describe_database` | Overview of registered tables and procedures. |

### Generic data access — any registered table (4)
| Tool | Purpose |
|------|---------|
| `list_table_records` | Paginated rows (`limit`, `offset`). |
| `get_table_record` | One row by primary key. |
| `search_table_records` | Text search across string columns. |
| `count_table_records` | Total row count. |

### Custom SQL (1)
| Tool | Purpose |
|------|---------|
| `execute_read_query` | Run a custom `SELECT` query. Rejects anything that is not `SELECT` or contains a forbidden keyword. |

### NE (Network Engineer) data (9)
| Tool | Purpose |
|------|---------|
| `setup_ne_tables` | Discover & register all NE tables. |
| `list_ne_tables` | List discovered/registered NE tables. |
| `describe_ne_data` | Overview of NE tables, columns, procedures. |
| `ne_data_summary` | Row counts across all NE tables. |
| `list_ne_records` | List rows from one NE table. |
| `get_ne_record` | One NE record by primary key. |
| `search_ne_records` | Search one NE table by text. |
| `search_all_ne_data` | Search across **all** NE tables at once. |
| `count_ne_records` | Count rows in one NE table. |

**Total: 20 tools** (11 general + 9 NE).

---

## 4. How "NE" tables are detected

A table is treated as NE (Network Engineer) data if **any** of the following is true
(logic in [app/ne_service.py](../app/ne_service.py)):

1. It is explicitly listed in the `NE_TABLES` environment variable, **or**
2. It lives in the schema named by `NE_SCHEMA`, **or**
3. Its name starts with `NE_TABLE_PREFIX` (default `ne`) or contains `_ne`, **or**
4. Its name matches a hint pattern: `ne_`, `_ne`, `ne_data`, `network_element`, etc.

---

## 5. Architecture

### 5.1 Component map

```
                    ┌──────────────────────────────────────────────┐
   MCP Client       │              MCP Server (this project)        │
 (Claude Desktop /  │                                              │
  MCP HTTP client)  │   app/server.py   ← entry point, 20 @tools   │
        │           │        │                                     │
        │  MCP       │        ├── TableService  (app/table_service) │
        │  protocol  │        ├── NEService     (app/ne_service)    │
        ├───────────►│        ├── TableRegistry (app/table_registry)│
        │  stdio or  │        ├── procedures    (app/procedures)    │
        │  HTTP      │        ├── table_refs     (helpers)          │
        │            │        ├── config        (app/config, .env)  │
        │            │        ├── logger        (app/logger → file) │
        │            │        └── Database       (app/database)     │
        └────────────┘                 │  asyncpg pool             │
                                        ▼                          │
                            ┌───────────────────────┐             │
                            │   PostgreSQL database  │◄────────────┘
                            │  (GIS + NE tables)     │
                            └───────────────────────┘
```

### 5.2 Module responsibilities

| File | Responsibility |
|------|----------------|
| [app/server.py](../app/server.py) | MCP entry point. Builds the `FastMCP` app, defines all 20 `@mcp.tool()` functions, wires up services, and manages startup/shutdown (`lifespan`). Runs with `transport="stdio"`. |
| [app/config.py](../app/config.py) | Loads configuration from `app/.env` into a frozen `DatabaseConfig` dataclass; builds the PostgreSQL DSN. |
| [app/database.py](../app/database.py) | Owns the `asyncpg` connection **pool**; schema introspection (`list_tables`, `get_table_schema`); safe query execution with auto-reconnect. |
| [app/procedures.py](../app/procedures.py) | Generates and installs per-table PostgreSQL functions: `<prefix>_list`, `_count`, `_search`, `_get_by_id`. All are `STABLE` (read-only). |
| [app/table_registry.py](../app/table_registry.py) | In-memory registry mapping `schema.table` → its `TableSchema` and generated procedure names. |
| [app/table_service.py](../app/table_service.py) | Business logic for generic table reads (list/get/search/count/describe) by calling the generated procedures. |
| [app/ne_service.py](../app/ne_service.py) | NE-specific discovery and read logic, including cross-table search. |
| [app/table_refs.py](../app/table_refs.py) | Small helpers to build/parse `schema.table` references. |
| [app/logger.py](../app/logger.py) | Configures **file-only** logging to `app/logs/mcp-server.log` (stdout/stderr are reserved for MCP). |

### 5.3 Request/data flow (example: "list 100 rows from ne_buildings")

1. The MCP client invokes the `list_ne_records` tool with `table_name="ne_buildings"`.
2. `server.py` → `NEService.list_ne_records` validates the table is a registered NE table.
3. It calls `TableService.list_records`, which looks up the generated function
   (e.g. `mcp_ne_buildings_list`) in the `TableRegistry`.
4. `Database.execute` runs `SELECT * FROM mcp_ne_buildings_list($1, $2)` on the connection pool.
5. Rows are serialised to JSON and returned to the client.

### 5.4 Startup behaviour (`lifespan`)

On start, the server:
1. Opens the PostgreSQL connection pool.
2. If `AUTO_SETUP_ALL_TABLES=true`, registers **all** tables and generates their functions.
3. If `AUTO_SETUP_NE_TABLES=true`, discovers & registers **NE** tables.
4. On shutdown, closes the pool cleanly.

---

## 6. Technology stack

| Layer | Technology |
|-------|------------|
| Language | Python 3.10+ (uses `X | None` type syntax and `from __future__ import annotations`) |
| MCP framework | `mcp` (FastMCP) `>= 1.2.0` |
| Database driver | `asyncpg` `>= 0.29.0` (async PostgreSQL) |
| Config | `python-dotenv` `>= 1.0.0` (reads `app/.env`) |
| Database | PostgreSQL |
| Concurrency | `asyncio` (async/await throughout) |
| Transport (as shipped) | MCP **stdio** |

Dependencies are pinned in [requirements.txt](../requirements.txt).

---

## 7. Configuration reference

Configuration is read from an `.env` file (see [.env.example](../.env.example)).

> **Note on `.env` location:** `app/config.py` loads `.env` from **its own directory**
> (`BASE_DIR / ".env"`, i.e. `app/.env`). Place the runtime `.env` inside the `app/` folder.
> A root `.env` is used only if your launch method sets the working directory / environment
> accordingly. The deployment guide sets environment variables explicitly to avoid ambiguity.

| Variable | Meaning | Default |
|----------|---------|---------|
| `DB_HOST` | PostgreSQL host | `localhost` |
| `DB_PORT` | PostgreSQL port | `5432` |
| `DB_NAME` | Database name | `postgres` |
| `DB_USER` | Username | `postgres` |
| `DB_PASSWORD` | Password | `` |
| `DB_SCHEMA` | Default schema | `public` |
| `DATABASE_URL` | Full DSN override (optional) | — |
| `AUTO_SETUP_ALL_TABLES` | Register all tables on startup | `false` |
| `NE_SCHEMA` | Dedicated schema for NE tables (optional) | — |
| `NE_TABLE_PREFIX` | Prefix used to detect NE tables | `ne` |
| `NE_TABLES` | Explicit comma-separated list of NE tables (optional) | — |
| `AUTO_SETUP_NE_TABLES` | Register NE tables on startup | `false` |

---

## 8. Security model

- **Read-only enforcement:** `execute_read_query` rejects anything that does not start with `SELECT`
  and blocks the keywords `INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE`. Generated functions are
  `STABLE`.
- **Recommended DB privileges:** Connect using a PostgreSQL role that only has `SELECT` (plus the
  ability to `CREATE FUNCTION` in the target schema if you use the auto-setup feature). This provides
  defence-in-depth even if the application-layer guard is bypassed.
- **Secrets:** Database credentials live in `.env`, which is git-ignored ([.gitignore](../.gitignore)).
- **Logging:** Logs go only to `app/logs/mcp-server.log`; protocol traffic stays on stdio.

> ⚠️ **Caveat:** The `execute_read_query` keyword filter is a simple safeguard, not a full SQL parser.
> The **primary** control should be a least-privileged, read-only database role. See the deployment
> guide's hardening section.

---

## 9. Project structure

```
MCP-SERVER-main/
├── app/
│   ├── server.py           # MCP entry point + 20 tool definitions
│   ├── config.py           # .env → DatabaseConfig
│   ├── database.py         # asyncpg pool + introspection
│   ├── procedures.py       # per-table stored-function generation
│   ├── table_registry.py   # in-memory registry
│   ├── table_service.py    # generic table read logic
│   ├── ne_service.py       # NE discovery & read logic
│   ├── table_refs.py       # schema.table helpers
│   ├── logger.py           # file-only logging
│   └── logs/               # runtime log output
├── requirements.txt        # Python dependencies
├── .env.example            # configuration template
├── .gitignore
├── readme.md               # original quick-start (Claude Desktop / stdio)
└── docs/                   # ← this documentation set
    ├── README.md
    ├── PROJECT_OVERVIEW.md
    └── DEPLOYMENT_IIS_WINDOWS_SERVER.md
```

---

## 10. How it is used today vs. how it will be deployed

| | Today (as shipped) | Target deployment |
|-|--------------------|-------------------|
| Transport | MCP **stdio** | MCP **HTTP** (Streamable HTTP) behind IIS |
| Launched by | Claude Desktop (as a child process, locally) | Windows Service + IIS reverse proxy |
| Reachable from | Local machine only | Over the network via a **domain name + HTTPS** |
| Client config | `claude_desktop_config.json` | MCP HTTP client pointed at `https://<domain>/mcp` |

The next document, [DEPLOYMENT_IIS_WINDOWS_SERVER.md](DEPLOYMENT_IIS_WINDOWS_SERVER.md), explains the
target deployment end-to-end.
