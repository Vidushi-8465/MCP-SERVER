from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

import asyncpg #asynchronous PostgreSQL driver

from config import DatabaseConfig, load_config
from logger import setup_logging

logger = setup_logging()


@dataclass
class ColumnInfo:
    name: str
    data_type: str
    is_nullable: bool
    column_default: str | None
    is_primary_key: bool

    @property
    def is_auto_generated(self) -> bool:
        return bool(self.column_default and "nextval" in self.column_default)


@dataclass
class TableSchema:
    schema_name: str
    table_name: str
    columns: list[ColumnInfo]

    @property
    def primary_key(self) -> str | None:
        for column in self.columns:
            if column.is_primary_key:
                return column.name
        return None

    @property
    def qualified_name(self) -> str:
        return f'"{self.schema_name}"."{self.table_name}"'

    @property
    def row_type(self) -> str:
        return f"{self.schema_name}.{self.table_name}"


class Database:
    def __init__(self, config: DatabaseConfig | None = None) -> None:
        self.config = config or load_config()
        self._pool: asyncpg.Pool | None = None

    async def connect(self) -> None:
        if self._pool is None:
            logger.info(
                "Connecting to PostgreSQL at %s:%s/%s",
                self.config.host,
                self.config.port,
                self.config.database,
            )
            self._pool = await asyncpg.create_pool(
                dsn=self.config.dsn,
                min_size=1,
                max_size=5,
                timeout=15,
                command_timeout=60,
            )
            logger.info("PostgreSQL connection pool ready")

    async def ensure_connected(self) -> None:
        try:
            pool = await self._get_pool()
            async with pool.acquire() as conn:
                await conn.fetchval("SELECT 1")
        except Exception:
            logger.warning("Connection lost, reconnecting...")
            await self.close()
            await self.connect()

    async def close(self) -> None:
        if self._pool is not None:
            await self._pool.close()
            self._pool = None

    async def _get_pool(self) -> asyncpg.Pool:
        if self._pool is None:
            await self.connect()
        assert self._pool is not None
        return self._pool

    async def _run(self, query: str, *args: Any, write: bool = False) -> str:
        await self.ensure_connected()
        pool = await self._get_pool()
        try:
            async with pool.acquire() as conn:
                if write:
                    result = await conn.fetchrow(query, *args)
                    if result is None:
                        return json.dumps({"success": True})
                    return json.dumps(dict(result), default=str)
                rows = await conn.fetch(query, *args)
                return json.dumps([dict(row) for row in rows], default=str)
        except Exception:
            logger.exception("Query failed: %s", query[:200])
            raise

    async def list_tables(self, schema_name: str | None = None) -> list[dict[str, str]]:
        schema = schema_name or self.config.schema
        await self.ensure_connected()
        pool = await self._get_pool()
        rows = await pool.fetch(
            """
            SELECT table_schema, table_name
            FROM information_schema.tables
            WHERE table_schema = $1
              AND table_type = 'BASE TABLE'
            ORDER BY table_name
            """,
            schema,
        )
        return [
            {"schema": row["table_schema"], "table": row["table_name"]}
            for row in rows
        ]

    async def list_tables_in_schemas(self, schemas: list[str]) -> list[dict[str, str]]:
        tables: list[dict[str, str]] = []
        for schema in schemas:
            tables.extend(await self.list_tables(schema))
        return tables

    async def get_table_schema(
        self,
        table_name: str,
        schema_name: str | None = None,
    ) -> TableSchema:
        schema = schema_name or self.config.schema
        await self.ensure_connected()
        pool = await self._get_pool()
        columns = await pool.fetch(
            """
            SELECT
                c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                CASE
                    WHEN pk.column_name IS NOT NULL THEN TRUE
                    ELSE FALSE
                END AS is_primary_key
            FROM information_schema.columns c
            LEFT JOIN (
                SELECT kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                  ON tc.constraint_name = kcu.constraint_name
                 AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                  AND tc.table_schema = $1
                  AND tc.table_name = $2
            ) pk ON pk.column_name = c.column_name
            WHERE c.table_schema = $1
              AND c.table_name = $2
            ORDER BY c.ordinal_position
            """,
            schema,
            table_name,
        )
        if not columns:
            raise ValueError(f"Table '{schema}.{table_name}' was not found.")

        return TableSchema(
            schema_name=schema,
            table_name=table_name,
            columns=[
                ColumnInfo(
                    name=row["column_name"],
                    data_type=row["data_type"],
                    is_nullable=row["is_nullable"] == "YES",
                    column_default=row["column_default"],
                    is_primary_key=row["is_primary_key"],
                )
                for row in columns
            ],
        )

    async def execute(self, query: str, *args: Any) -> str:
        return await self._run(query, *args, write=False)

    async def execute_write(self, query: str, *args: Any) -> str:
        return await self._run(query, *args, write=True)
