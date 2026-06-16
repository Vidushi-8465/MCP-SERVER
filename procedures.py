from __future__ import annotations

from database import Database, TableSchema
from table_registry import TableRegistry, sanitize_name


def _quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _proc_prefix(table_name: str) -> str:
    return f"mcp_{sanitize_name(table_name)}"


def generate_list_procedure(schema: TableSchema) -> str:
    prefix = _proc_prefix(schema.table_name)
    qualified = schema.qualified_name
    return f"""
CREATE OR REPLACE FUNCTION {prefix}_list(
    p_limit INT DEFAULT 100,
    p_offset INT DEFAULT 0
)
RETURNS SETOF {schema.row_type}
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM {qualified}
    ORDER BY 1
    LIMIT p_limit OFFSET p_offset;
$$;
""".strip()


def generate_count_procedure(schema: TableSchema) -> str:
    prefix = _proc_prefix(schema.table_name)
    qualified = schema.qualified_name
    return f"""
CREATE OR REPLACE FUNCTION {prefix}_count()
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COUNT(*)::BIGINT FROM {qualified};
$$;
""".strip()


def generate_search_procedure(schema: TableSchema) -> str:
    prefix = _proc_prefix(schema.table_name)
    qualified = schema.qualified_name
    text_columns = [
        column
        for column in schema.columns
        if column.data_type in ("character varying", "text", "character")
    ]
    if not text_columns:
        text_columns = schema.columns[:3]

    conditions = " OR ".join(
        f"{_quote_ident(column.name)}::TEXT ILIKE '%' || p_query || '%'"
        for column in text_columns
    )
    return f"""
CREATE OR REPLACE FUNCTION {prefix}_search(
    p_query TEXT,
    p_limit INT DEFAULT 50
)
RETURNS SETOF {schema.row_type}
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM {qualified}
    WHERE {conditions}
    LIMIT p_limit;
$$;
""".strip()


def generate_get_by_id_procedure(schema: TableSchema) -> str:
    if not schema.primary_key:
        raise ValueError(
            f"Table '{schema.table_name}' has no primary key for get_by_id."
        )

    prefix = _proc_prefix(schema.table_name)
    qualified = schema.qualified_name
    pk = _quote_ident(schema.primary_key)
    pk_type = next(
        column.data_type
        for column in schema.columns
        if column.name == schema.primary_key
    )
    return f"""
CREATE OR REPLACE FUNCTION {prefix}_get_by_id(p_id {pk_type})
RETURNS {schema.row_type}
LANGUAGE sql
STABLE
AS $$
    SELECT * FROM {qualified} WHERE {pk} = p_id LIMIT 1;
$$;
""".strip()


def _build_procedure_set(schema: TableSchema) -> dict[str, str]:
    statements: dict[str, str] = {
        "list": generate_list_procedure(schema),
        "count": generate_count_procedure(schema),
        "search": generate_search_procedure(schema),
    }
    if schema.primary_key:
        statements["get_by_id"] = generate_get_by_id_procedure(schema)
    return statements


async def create_table_procedures(
    db: Database,
    table_name: str,
    registry: TableRegistry,
    schema_name: str | None = None,
) -> dict[str, str]:
    schema = await db.get_table_schema(table_name, schema_name)
    statements = _build_procedure_set(schema)

    await db.ensure_connected()
    pool = await db._get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            for sql in statements.values():
                await conn.execute(sql)

    prefix = _proc_prefix(table_name)
    procedures = {name: f"{prefix}_{name}" for name in statements}
    registry.register(schema, procedures)
    return procedures


async def setup_all_table_procedures(
    db: Database,
    registry: TableRegistry,
    schema_name: str | None = None,
) -> dict:
    tables = await db.list_tables(schema_name)
    success: list[dict] = []
    failed: list[dict] = []

    for table in tables:
        name = table["table"]
        table_schema = table["schema"]
        table_ref = f"{table_schema}.{name}"
        try:
            procedures = await create_table_procedures(
                db, name, registry=registry, schema_name=table_schema
            )
            schema = registry.get_schema(table_ref)
            success.append(
                {
                    "table_ref": table_ref,
                    "primary_key": schema.primary_key,
                    "procedures": procedures,
                }
            )
        except Exception as exc:
            failed.append({"table_ref": table_ref, "error": str(exc)})

    return {
        "message": f"Registered {len(success)} of {len(tables)} tables.",
        "success_count": len(success),
        "failed_count": len(failed),
        "success": success,
        "failed": failed,
    }
