from __future__ import annotations

import json
from typing import Any

from database import Database
from logger import setup_logging
from table_refs import make_table_ref
from table_registry import TableRegistry
from table_service import TableService

logger = setup_logging()

NE_TABLE_HINTS = ("ne_", "_ne", "ne_data", "Network Engineer", "network_element")


class NEService:
    def __init__(
        self,
        db: Database,
        registry: TableRegistry,
        table_service: TableService,
    ) -> None:
        self.db = db
        self.registry = registry
        self.tables = table_service
        self._ne_table_refs: list[str] = []

    def _schemas_to_scan(self) -> list[str]:
        schemas = [self.db.config.schema]
        if self.db.config.ne_schema and self.db.config.ne_schema not in schemas:
            schemas.append(self.db.config.ne_schema)
        return schemas

    def is_ne_table(self, schema_name: str, table_name: str) -> bool:
        if self.db.config.ne_schema and schema_name.lower() == self.db.config.ne_schema.lower():
            return True
        lower = table_name.lower()
        prefix = self.db.config.ne_table_prefix.lower()
        if prefix and (lower.startswith(prefix) or f"_{prefix}" in lower):
            return True
        return any(hint in lower for hint in NE_TABLE_HINTS)

    async def discover_ne_tables(self) -> list[dict[str, str]]:
        all_tables = await self.db.list_tables_in_schemas(self._schemas_to_scan())
        return [
            table
            for table in all_tables
            if self.is_ne_table(table["schema"], table["table"])
        ]

    async def setup_ne_tables(self) -> dict[str, Any]:
        ne_tables = await self.discover_ne_tables()
        success: list[dict] = []
        failed: list[dict] = []
        registered_refs: list[str] = []

        for table in ne_tables:
            table_ref = make_table_ref(table["schema"], table["table"])
            try:
                result = await self.tables.setup_table(
                    table["table"], schema_name=table["schema"]
                )
                success.append(result)
                registered_refs.append(table_ref)
            except Exception as exc:
                failed.append({"table_ref": table_ref, "error": str(exc)})

        self._ne_table_refs = registered_refs
        logger.info("NE setup: %d succeeded, %d failed", len(success), len(failed))
        return {
            "message": f"Registered {len(success)} of {len(ne_tables)} NE tables.",
            "success_count": len(success),
            "failed_count": len(failed),
            "success": success,
            "failed": failed,
        }

    def _registered_ne_tables(self) -> list[str]:
        if self._ne_table_refs:
            return [ref for ref in self._ne_table_refs if self.registry.is_registered(ref)]
        return [
            ref
            for ref in self.registry.table_names
            if self.is_ne_table(*ref.split(".", 1))
        ]

    def _require_ne_table(self, table_name: str) -> str:
        schema_name, name = (
            table_name.split(".", 1)
            if "." in table_name
            else (self.db.config.schema, table_name)
        )
        table_ref = make_table_ref(schema_name, name)
        if not self.is_ne_table(schema_name, name):
            raise ValueError(f"'{table_ref}' is not recognized as an NE table.")
        if not self.registry.is_registered(table_ref):
            raise ValueError(
                f"NE table '{table_ref}' is not registered. Call setup_ne_tables first."
            )
        return table_ref

    async def list_ne_tables(self) -> str:
        discovered = await self.discover_ne_tables()
        registered = self._registered_ne_tables()
        return json.dumps(
            {
                "discovered_count": len(discovered),
                "registered_count": len(registered),
                "discovered": [
                    make_table_ref(t["schema"], t["table"]) for t in discovered
                ],
                "registered": registered,
            },
            indent=2,
        )

    async def describe_ne_data(self) -> str:
        registered = self._registered_ne_tables()
        if not registered:
            discovered = await self.discover_ne_tables()
            preview = []
            for table in discovered:
                schema = await self.db.get_table_schema(
                    table["table"], table["schema"]
                )
                preview.append(
                    {
                        "table_ref": make_table_ref(schema.schema_name, schema.table_name),
                        "primary_key": schema.primary_key,
                        "columns": [c.name for c in schema.columns],
                        "registered": False,
                    }
                )
            return json.dumps(
                {
                    "message": "NE tables found but not set up. Call setup_ne_tables.",
                    "table_count": len(preview),
                    "tables": preview,
                },
                indent=2,
            )

        tables = []
        for table_ref in registered:
            schema = self.registry.get_schema(table_ref)
            tables.append(
                {
                    "table_ref": table_ref,
                    "primary_key": schema.primary_key,
                    "column_count": len(schema.columns),
                    "columns": [c.name for c in schema.columns],
                    "procedures": self.registry.get_procedures(table_ref),
                }
            )
        return json.dumps(
            {"ne_table_count": len(tables), "tables": tables},
            indent=2,
        )

    async def ne_data_summary(self) -> str:
        registered = self._registered_ne_tables()
        if not registered:
            raise ValueError("No NE tables registered. Call setup_ne_tables first.")

        summary = []
        for table_ref in registered:
            count_json = await self.tables.count_records(table_ref)
            count = json.loads(count_json)["count"]
            schema = self.registry.get_schema(table_ref)
            summary.append(
                {
                    "table_ref": table_ref,
                    "row_count": count,
                    "primary_key": schema.primary_key,
                }
            )
        return json.dumps(
            {
                "ne_table_count": len(summary),
                "total_rows": sum(item["row_count"] for item in summary),
                "tables": summary,
            },
            indent=2,
        )

    async def list_ne_records(
        self, table_name: str, limit: int = 100, offset: int = 0
    ) -> str:
        table_ref = self._require_ne_table(table_name)
        rows = await self.tables.list_records(table_ref, limit, offset)
        parsed = json.loads(rows)
        return json.dumps(
            {"table": table_ref, "count": len(parsed), "records": parsed},
            default=str,
            indent=2,
        )

    async def get_ne_record(self, table_name: str, record_id: str) -> str:
        table_ref = self._require_ne_table(table_name)
        return await self.tables.get_record(table_ref, record_id)

    async def search_ne_records(
        self, table_name: str, query: str, limit: int = 50
    ) -> str:
        table_ref = self._require_ne_table(table_name)
        return await self.tables.search_records(table_ref, query, limit)

    async def count_ne_records(self, table_name: str) -> str:
        table_ref = self._require_ne_table(table_name)
        return await self.tables.count_records(table_ref)

    async def search_all_ne_data(self, query: str, limit_per_table: int = 10) -> str:
        registered = self._registered_ne_tables()
        if not registered:
            raise ValueError("No NE tables registered. Call setup_ne_tables first.")

        results = []
        for table_ref in registered:
            try:
                raw = await self.tables.search_records(table_ref, query, limit_per_table)
                parsed = json.loads(raw)
                if parsed.get("records"):
                    results.append(parsed)
            except Exception as exc:
                results.append({"table": table_ref, "error": str(exc)})

        return json.dumps(
            {
                "query": query,
                "tables_searched": len(registered),
                "tables_with_matches": len(results),
                "results": results,
            },
            default=str,
            indent=2,
        )

    async def create_ne_record(self, table_name: str, data: dict[str, Any]) -> str:
        table_ref = self._require_ne_table(table_name)
        return await self.tables.create_record(table_ref, data)

    async def update_ne_record(
        self, table_name: str, record_id: str, data: dict[str, Any]
    ) -> str:
        table_ref = self._require_ne_table(table_name)
        return await self.tables.update_record(table_ref, record_id, data)

    async def delete_ne_record(self, table_name: str, record_id: str) -> str:
        table_ref = self._require_ne_table(table_name)
        return await self.tables.delete_record(table_ref, record_id)
