from __future__ import annotations

import json
from typing import Any

from database import Database
from logger import setup_logging
from procedures import create_table_procedures, setup_all_table_procedures
from table_refs import parse_table_ref
from table_registry import TableRegistry

logger = setup_logging()


class TableService:
    def __init__(self, db: Database, registry: TableRegistry) -> None:
        self.db = db
        self.registry = registry

    def _table_key(self, table_name: str, schema_name: str | None = None) -> str:
        default = schema_name or self.db.config.schema
        schema, name = parse_table_ref(table_name, default)
        return f"{schema}.{name}"

    async def setup_table(
        self, table_name: str, schema_name: str | None = None
    ) -> dict[str, Any]:
        schema, name = parse_table_ref(table_name, schema_name or self.db.config.schema)
        if schema_name:
            schema = schema_name
        procedures = await create_table_procedures(
            self.db, name, registry=self.registry, schema_name=schema
        )
        table_ref = f"{schema}.{name}"
        table_schema = self.registry.get_schema(table_ref)
        return {
            "table_ref": table_ref,
            "primary_key": table_schema.primary_key,
            "procedures": procedures,
        }

    async def setup_all_tables(self, schema_name: str | None = None) -> dict[str, Any]:
        result = await setup_all_table_procedures(
            self.db, self.registry, schema_name=schema_name
        )
        logger.info(
            "Setup complete: %d succeeded, %d failed",
            len(result["success"]),
            len(result["failed"]),
        )
        return result

    async def list_records(
        self, table_name: str, limit: int = 100, offset: int = 0
    ) -> str:
        table_ref = self._table_key(table_name)
        proc = self.registry.get_procedure(table_ref, "list")
        return await self.db.execute(
            f"SELECT * FROM {proc}($1, $2)",
            limit,
            offset,
        )

    async def get_record(self, table_name: str, record_id: str) -> str:
        table_ref = self._table_key(table_name)
        schema = self.registry.get_schema(table_ref)
        if not schema.primary_key:
            raise ValueError(f"Table '{table_ref}' has no primary key.")

        proc = self.registry.get_procedure(table_ref, "get_by_id")
        rows = await self.db.execute(f"SELECT * FROM {proc}($1)", record_id)
        parsed = json.loads(rows)
        if not parsed:
            return json.dumps({"found": False, "table": table_ref, "id": record_id})
        return json.dumps(
            {"found": True, "table": table_ref, "record": parsed[0]},
            default=str,
            indent=2,
        )

    async def create_record(self, table_name: str, data: dict[str, Any]) -> str:
        table_ref = self._table_key(table_name)
        schema = self.registry.get_schema(table_ref)
        insertable = [c for c in schema.columns if not c.is_auto_generated]
        if not insertable:
            raise ValueError(f"Table '{table_ref}' has no insertable columns.")

        missing = [
            c.name for c in insertable if not c.is_nullable and c.name not in data
        ]
        if missing:
            raise ValueError(f"Missing required columns: {', '.join(missing)}")

        proc = self.registry.get_procedure(table_ref, "insert")
        placeholders = ", ".join(f"${i + 1}" for i in range(len(insertable)))
        values = [data.get(c.name) for c in insertable]
        result = await self.db.execute_write(
            f"SELECT * FROM {proc}({placeholders})",
            *values,
        )
        return json.dumps(
            {"table": table_ref, "created": json.loads(result)},
            default=str,
            indent=2,
        )

    async def update_record(
        self, table_name: str, record_id: str, data: dict[str, Any]
    ) -> str:
        table_ref = self._table_key(table_name)
        schema = self.registry.get_schema(table_ref)
        if not schema.primary_key:
            raise ValueError(f"Table '{table_ref}' has no primary key.")

        updatable = [c for c in schema.columns if c.name != schema.primary_key]
        if not updatable:
            raise ValueError(f"Table '{table_ref}' has no updatable columns.")

        proc = self.registry.get_procedure(table_ref, "update")
        placeholders = ", ".join(f"${i + 2}" for i in range(len(updatable)))
        values = [record_id] + [data.get(c.name) for c in updatable]
        result = await self.db.execute_write(
            f"SELECT * FROM {proc}($1, {placeholders})",
            *values,
        )
        return json.dumps(
            {"table": table_ref, "updated": json.loads(result)},
            default=str,
            indent=2,
        )

    async def delete_record(self, table_name: str, record_id: str) -> str:
        table_ref = self._table_key(table_name)
        proc = self.registry.get_procedure(table_ref, "delete")
        result = await self.db.execute_write(
            f"SELECT {proc}($1) AS deleted",
            record_id,
        )
        return json.dumps(
            {"table": table_ref, **json.loads(result)},
            default=str,
            indent=2,
        )

    async def count_records(self, table_name: str) -> str:
        table_ref = self._table_key(table_name)
        proc = self.registry.get_procedure(table_ref, "count")
        result = await self.db.execute(f"SELECT {proc}() AS count")
        parsed = json.loads(result)
        count = parsed[0]["count"] if parsed else 0
        return json.dumps({"table": table_ref, "count": count}, indent=2)

    async def search_records(
        self,
        table_name: str,
        query: str,
        limit: int = 50,
    ) -> str:
        table_ref = self._table_key(table_name)
        proc = self.registry.get_procedure(table_ref, "search")
        rows = await self.db.execute(
            f"SELECT * FROM {proc}($1, $2)",
            query,
            limit,
        )
        parsed = json.loads(rows)
        return json.dumps(
            {
                "table": table_ref,
                "query": query,
                "count": len(parsed),
                "records": parsed,
            },
            default=str,
            indent=2,
        )

    async def describe_database(self) -> str:
        if not self.registry.table_names:
            tables = await self.db.list_tables()
            schemas = []
            for table in tables:
                schema = await self.db.get_table_schema(
                    table["table"], table["schema"]
                )
                schemas.append(
                    {
                        "table_ref": f"{schema.schema_name}.{schema.table_name}",
                        "primary_key": schema.primary_key,
                        "columns": [c.name for c in schema.columns],
                        "registered": False,
                    }
                )
            return json.dumps(
                {
                    "message": "Tables discovered but not set up. Call setup_all_tables.",
                    "table_count": len(schemas),
                    "tables": schemas,
                },
                indent=2,
            )

        return json.dumps(
            {
                "table_count": len(self.registry.table_names),
                "tables": self.registry.summary(),
            },
            indent=2,
        )
