# PostgreSQL MCP Server

Multi-table MCP server for Claude Desktop that connects to PostgreSQL and exposes database tools for discovery, CRUD, search, custom read queries, and **NE (Northeast) region data**.

## Quick start

1. Install dependencies: `pip install -r requirements.txt`
2. Copy `.env.example` to `.env` and fill in your DBeaver/PostgreSQL credentials
3. Add the server to Claude Desktop config (see [Claude Desktop setup](#claude-desktop-setup))
4. Restart Claude Desktop
5. Ask Claude to run `setup_all_tables` and/or `setup_ne_tables` (or enable auto-setup in `.env`)

---

## All 26 tools

### Discovery & setup — general (6 tools)

| Tool | What it does |
|------|----------------|
| `list_tables` | Lists all tables in the default schema |
| `get_table_schema` | Shows columns, types, and primary key for any table |
| `setup_all_tables` | Registers all tables and creates stored procedures |
| `setup_table` | Registers a single table |
| `list_registered_tables` | Shows which tables are ready to use |
| `describe_database` | Overview of registered tables and procedures |

### Data access — any registered table (7 tools)

Pass `table_name` (use `schema.table` format when needed, e.g. `public.ne_buildings`):

| Tool | What it does |
|------|----------------|
| `list_table_records` | Paginated list of rows |
| `get_table_record` | One row by primary key |
| `search_table_records` | Text search across string columns |
| `count_table_records` | Total row count |
| `create_table_record` | Insert a row |
| `update_table_record` | Update by primary key |
| `delete_table_record` | Delete by primary key |

### Custom SQL (1 tool)

| Tool | What it does |
|------|----------------|
| `execute_read_query` | Run any `SELECT` query (joins, reports, analytics) |

### NE (Netwrok Engineer) data tools (12 tools)

For tables in the NE schema or whose names match the NE prefix (e.g. `ne_buildings`, `ne_sites`):

| Tool | What it does |
|------|----------------|
| `setup_ne_tables` | Discover and register all NE tables with stored procedures |
| `list_ne_tables` | List discovered and registered NE tables |
| `describe_ne_data` | Overview of NE tables, columns, and procedures |
| `ne_data_summary` | Row counts across all NE tables |
| `list_ne_records` | List rows from a specific NE table |
| `get_ne_record` | Get one NE record by primary key |
| `search_ne_records` | Search one NE table by text |
| `search_all_ne_data` | Search across **all** NE tables at once |
| `count_ne_records` | Count rows in one NE table |
| `create_ne_record` | Insert into an NE table |
| `update_ne_record` | Update an NE record |
| `delete_ne_record` | Delete an NE record |

---

## How NE tables are detected

A table is treated as NE data if **any** of these match:

1. It lives in the schema set by `NE_SCHEMA` (e.g. `ne`)
2. Its name starts with `NE_TABLE_PREFIX` (default: `ne`)
3. Its name contains patterns like `ne_`, `_ne`, `network_engineer`, `network_element`

Configure in `.env`:

```env
NE_SCHEMA=ne          # optional — dedicated NE schema
NE_TABLE_PREFIX=ne      # table name prefix in public schema
AUTO_SETUP_NE_TABLES=true
```

---

## Database coverage

### Works immediately (no setup required)

- `list_tables`
- `get_table_schema`
- `execute_read_query`

### Requires table registration

Generic CRUD tools and NE tools need tables registered via `setup_all_tables`, `setup_table`, or `setup_ne_tables`.

### Scope limits

| Limit | Detail |
|-------|--------|
| Default schema | `DB_SCHEMA` (default: `public`) |
| NE schema | Optional separate schema via `NE_SCHEMA` |
| Registration | Some tables may fail setup (missing PK, type errors) |
| Procedures | `list`, `count`, `search`, `insert` on all registered tables |
| Primary key | `get`, `update`, `delete` require a primary key |

### Summary

| Question | Answer |
|----------|--------|
| How many tools? | **26** (14 general + 12 NE) |
| NE data supported? | **Yes** — dedicated NE tools + auto-discovery |
| Same tools for every table? | Yes — pass `table_name` or use NE tools |
| Works without setup? | Only discovery + `execute_read_query` |

---

## Workflow in Claude

### General data

1. `setup_all_tables` → register everything
2. `describe_database` → see what's ready
3. `list_table_records` with `table_name`

### NE data

1. `setup_ne_tables` → register NE tables only
2. `describe_ne_data` or `ne_data_summary` → overview
3. `list_ne_records`, `search_ne_records`, or `search_all_ne_data`

**Example prompts:**

> "Run setup_ne_tables and show me a summary of all NE data."

> "Search all NE tables for 'Guwahati'."

> "List 20 records from ne_buildings."

> "Count rows in every NE table."

---

## Setup

### Install dependencies

```powershell
cd c:\Vidushi\mcp-server
pip install -r requirements.txt
```

### Environment variables (`.env`)

```env
DB_HOST=your_host
DB_PORT=5432
DB_NAME=postgres
DB_USER=postgres
DB_PASSWORD=your_password
DB_SCHEMA=public
AUTO_SETUP_ALL_TABLES=true

# NE (Network Engineer) data
NE_SCHEMA=
NE_TABLE_PREFIX=ne
AUTO_SETUP_NE_TABLES=true
```

| Variable | Description |
|----------|-------------|
| `DB_HOST` | PostgreSQL host |
| `DB_PORT` | Port (default: 5432) |
| `DB_NAME` | Database name |
| `DB_USER` | Username |
| `DB_PASSWORD` | Password |
| `DB_SCHEMA` | Default schema (default: `public`) |
| `AUTO_SETUP_ALL_TABLES` | Register all tables on startup |
| `NE_SCHEMA` | Optional dedicated schema for NE tables |
| `NE_TABLE_PREFIX` | Prefix to match NE table names (default: `ne`) |
| `AUTO_SETUP_NE_TABLES` | Register NE tables on startup |

### Claude Desktop setup

Add to `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "postgres": {
      "command": "python",
      "args": ["c:\\Vidushi\\mcp-server\\server.py"],
      "env": {
        "DB_HOST": "your_host",
        "DB_PORT": "5432",
        "DB_NAME": "postgres",
        "DB_USER": "postgres",
        "DB_PASSWORD": "your_password",
        "DB_SCHEMA": "public",
        "AUTO_SETUP_ALL_TABLES": "true",
        "NE_TABLE_PREFIX": "ne",
        "AUTO_SETUP_NE_TABLES": "true"
      }
    }
  }
}
```

Restart Claude Desktop after saving.

### Logs

```
c:\Vidushi\mcp-server\logs\mcp-server.log
```

> MCP uses stdio for protocol traffic. Logs go to the file only, not the console.

---

## Project structure

```
mcp-server/
├── server.py           # MCP entry point and tool definitions
├── database.py         # PostgreSQL connection pool
├── config.py           # Environment configuration
├── logger.py           # File-based logging
├── procedures.py       # Stored procedure generation
├── table_registry.py   # Tracks registered tables
├── table_service.py    # Multi-table CRUD logic
├── table_refs.py       # schema.table reference helpers
├── ne_service.py       # NE data discovery and operations
├── requirements.txt
├── .env
├── .env.example
├── readme.md
└── logs/
```

---

## Run manually

```powershell
python server.py
```
