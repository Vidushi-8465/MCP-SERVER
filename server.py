"""
PostgreSQL MCP Server

Multi-table database access with stored procedures and NE (Network Engineer) data tools.
Run: python server.py
"""

from __future__ import annotations

import functools
import json
from contextlib import asynccontextmanager
from typing import Any, Callable

from mcp.server.fastmcp import FastMCP

from database import Database
from logger import LOG_FILE, setup_logging
from ne_service import NEService
from table_registry import TableRegistry
from table_service import TableService

logger = setup_logging()
db = Database()
registry = TableRegistry()
tables = TableService(db, registry)
ne = NEService(db, registry, tables)

INSTRUCTIONS = (
    "PostgreSQL MCP Server with access to ALL database tables and NE (Netwrok Engineer) data. "
    "Workflow: 1) setup_all_tables or setup_ne_tables to register tables, "
    "2) describe_database / describe_ne_data to see what's available, "
    "3) use generic table tools with table_name, or NE-specific tools "
    "(list_ne_records, get_ne_record, search_ne_records, search_all_ne_data, etc.). "
    "Table references use schema.table format when needed (e.g. public.ne_buildings)."
)


def log_tool(func: Callable) -> Callable:
    @functools.wraps(func)
    async def wrapper(*args: Any, **kwargs: Any) -> str:
        logger.info("Tool called: %s", func.__name__)
        try:
            result = await func(*args, **kwargs)
            logger.info("Tool finished: %s", func.__name__)
            return result
        except Exception:
            logger.exception("Tool failed: %s", func.__name__)
            raise

    return wrapper


@asynccontextmanager
async def lifespan(_: FastMCP):
    logger.info("MCP server starting (logs: %s)", LOG_FILE)
    try:
        await db.connect()
        if db.config.auto_setup_all_tables:
            logger.info("AUTO_SETUP_ALL_TABLES enabled — registering all tables")
            await tables.setup_all_tables()
        if db.config.auto_setup_ne_tables:
            logger.info("AUTO_SETUP_NE_TABLES enabled — registering NE tables")
            await ne.setup_ne_tables()
    except Exception as exc:
        logger.error("Startup failed: %s", exc)
    try:
        yield
    finally:
        await db.close()
        logger.info("MCP server stopped")


mcp = FastMCP(
    "postgres-mcp-server",
    instructions=INSTRUCTIONS,
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Discovery & setup
# ---------------------------------------------------------------------------


@mcp.tool()
@log_tool
async def list_tables() -> str:
    """List all tables in the default database schema."""
    result = await db.list_tables()
    return json.dumps(result, indent=2)


@mcp.tool()
@log_tool
async def get_table_schema(table_name: str, schema_name: str | None = None) -> str:
    """Inspect columns, types, and primary key for any table."""
    schema = await db.get_table_schema(table_name, schema_name)
    return json.dumps(
        {
            "table_ref": f"{schema.schema_name}.{schema.table_name}",
            "schema": schema.schema_name,
            "table": schema.table_name,
            "primary_key": schema.primary_key,
            "columns": [
                {
                    "name": c.name,
                    "type": c.data_type,
                    "nullable": c.is_nullable,
                    "default": c.column_default,
                    "primary_key": c.is_primary_key,
                }
                for c in schema.columns
            ],
        },
        indent=2,
    )


@mcp.tool()
@log_tool
async def setup_all_tables() -> str:
    """Register ALL tables and create stored procedures for each."""
    result = await tables.setup_all_tables()
    return json.dumps(result, indent=2)


@mcp.tool()
@log_tool
async def setup_table(table_name: str, schema_name: str | None = None) -> str:
    """Register a single table and create its stored procedures."""
    result = await tables.setup_table(table_name, schema_name)
    return json.dumps(result, indent=2)


@mcp.tool()
@log_tool
async def list_registered_tables() -> str:
    """List all tables that have been set up and are ready to use."""
    if not registry.table_names:
        return json.dumps(
            {
                "message": "No tables registered yet. Call setup_all_tables first.",
                "tables": [],
            },
            indent=2,
        )
    return json.dumps(
        {"table_count": len(registry.table_names), "tables": registry.summary()},
        indent=2,
    )


@mcp.tool()
@log_tool
async def describe_database() -> str:
    """Overview of all tables, columns, and available procedures."""
    return await tables.describe_database()


# ---------------------------------------------------------------------------
# Generic multi-table CRUD
# ---------------------------------------------------------------------------


@mcp.tool()
@log_tool
async def list_table_records(
    table_name: str,
    limit: int = 100,
    offset: int = 0,
) -> str:
    """List rows from any registered table (use schema.table if needed)."""
    rows = await tables.list_records(table_name, limit, offset)
    parsed = json.loads(rows)
    return json.dumps(
        {"table": table_name, "count": len(parsed), "records": parsed},
        default=str,
        indent=2,
    )


@mcp.tool()
@log_tool
async def get_table_record(table_name: str, record_id: str) -> str:
    """Get a single row by primary key from any registered table."""
    return await tables.get_record(table_name, record_id)


@mcp.tool()
@log_tool
async def search_table_records(
    table_name: str,
    query: str,
    limit: int = 50,
) -> str:
    """Search any registered table by text across its string columns."""
    return await tables.search_records(table_name, query, limit)


@mcp.tool()
@log_tool
async def count_table_records(table_name: str) -> str:
    """Count total rows in any registered table."""
    return await tables.count_records(table_name)


@mcp.tool()
@log_tool
async def create_table_record(table_name: str, data: dict[str, Any]) -> str:
    """Insert a new row into any registered table."""
    return await tables.create_record(table_name, data)


@mcp.tool()
@log_tool
async def update_table_record(
    table_name: str,
    record_id: str,
    data: dict[str, Any],
) -> str:
    """Update a row by primary key in any registered table."""
    return await tables.update_record(table_name, record_id, data)


@mcp.tool()
@log_tool
async def delete_table_record(table_name: str, record_id: str) -> str:
    """Delete a row by primary key from any registered table."""
    return await tables.delete_record(table_name, record_id)


@mcp.tool()
@log_tool
async def execute_read_query(sql: str) -> str:
    """Run a custom read-only SELECT query (joins, reports, analytics)."""
    normalized = sql.strip().upper()
    if not normalized.startswith("SELECT"):
        raise ValueError("Only SELECT queries are allowed.")
    forbidden = ("INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "TRUNCATE")
    if any(keyword in normalized for keyword in forbidden):
        raise ValueError("Query contains forbidden keywords.")
    return await db.execute(sql)


# ---------------------------------------------------------------------------
# NE (Netwrok Engineer) data tools
# ---------------------------------------------------------------------------


@mcp.tool()
@log_tool
async def setup_ne_tables() -> str:
    """
    Discover and register all NE tables (Network Engineer region data).
    Matches tables in NE_SCHEMA or whose names contain the NE prefix (e.g. ne_buildings).
    Creates stored procedures for each NE table.
    """
    result = await ne.setup_ne_tables()
    return json.dumps(result, indent=2)


@mcp.tool()
@log_tool
async def list_ne_tables() -> str:
    """List all discovered and registered NE tables."""
    return await ne.list_ne_tables()


@mcp.tool()
@log_tool
async def describe_ne_data() -> str:
    """Overview of NE tables, columns, and available procedures."""
    return await ne.describe_ne_data()


@mcp.tool()
@log_tool
async def ne_data_summary() -> str:
    """Row counts and summary statistics across all registered NE tables."""
    return await ne.ne_data_summary()


@mcp.tool()
@log_tool
async def list_ne_records(
    table_name: str,
    limit: int = 100,
    offset: int = 0,
) -> str:
    """List rows from a specific NE table."""
    return await ne.list_ne_records(table_name, limit, offset)


@mcp.tool()
@log_tool
async def get_ne_record(table_name: str, record_id: str) -> str:
    """Get one NE record by primary key."""
    return await ne.get_ne_record(table_name, record_id)


@mcp.tool()
@log_tool
async def search_ne_records(
    table_name: str,
    query: str,
    limit: int = 50,
) -> str:
    """Search a specific NE table by text."""
    return await ne.search_ne_records(table_name, query, limit)


@mcp.tool()
@log_tool
async def search_all_ne_data(query: str, limit_per_table: int = 10) -> str:
    """Search across ALL registered NE tables at once."""
    return await ne.search_all_ne_data(query, limit_per_table)


@mcp.tool()
@log_tool
async def count_ne_records(table_name: str) -> str:
    """Count rows in a specific NE table."""
    return await ne.count_ne_records(table_name)


@mcp.tool()
@log_tool
async def create_ne_record(table_name: str, data: dict[str, Any]) -> str:
    """Insert a new row into an NE table."""
    return await ne.create_ne_record(table_name, data)


@mcp.tool()
@log_tool
async def update_ne_record(
    table_name: str,
    record_id: str,
    data: dict[str, Any],
) -> str:
    """Update a row in an NE table by primary key."""
    return await ne.update_ne_record(table_name, record_id, data)


@mcp.tool()
@log_tool
async def delete_ne_record(table_name: str, record_id: str) -> str:
    """Delete a row from an NE table by primary key."""
    return await ne.delete_ne_record(table_name, record_id)


if __name__ == "__main__":
    mcp.run(transport="stdio")
