from __future__ import annotations

from database import TableSchema
from table_refs import make_table_ref


def sanitize_name(name: str) -> str:
    return name.replace("-", "_").replace(" ", "_").lower()


class TableRegistry:
    def __init__(self) -> None:
        self._schemas: dict[str, TableSchema] = {}
        self._procedures: dict[str, dict[str, str]] = {}

    @staticmethod
    def key_for(schema: TableSchema) -> str:
        return make_table_ref(schema.schema_name, schema.table_name)

    @property
    def table_names(self) -> list[str]:
        return sorted(self._schemas.keys())

    def is_registered(self, table_ref: str) -> bool:
        return table_ref in self._schemas

    def register(self, schema: TableSchema, procedures: dict[str, str]) -> None:
        key = self.key_for(schema)
        self._schemas[key] = schema
        self._procedures[key] = procedures

    def get_schema(self, table_ref: str) -> TableSchema:
        schema = self._schemas.get(table_ref)
        if schema is None:
            registered = ", ".join(self.table_names) or "(none)"
            raise ValueError(
                f"Table '{table_ref}' is not registered. "
                f"Call setup_all_tables or setup_table first. "
                f"Registered tables: {registered}"
            )
        return schema

    def get_procedure(self, table_ref: str, action: str) -> str:
        procedures = self._procedures.get(table_ref)
        if not procedures:
            raise ValueError(f"Table '{table_ref}' has no registered procedures.")
        proc = procedures.get(action)
        if not proc:
            raise ValueError(
                f"Procedure '{action}' not available for table '{table_ref}'. "
                f"Available: {', '.join(procedures.keys())}"
            )
        return proc

    def get_procedures(self, table_ref: str) -> dict[str, str]:
        return self._procedures.get(table_ref, {})

    def summary(self) -> list[dict]:
        return [
            {
                "table_ref": key,
                "schema": schema.schema_name,
                "table": schema.table_name,
                "primary_key": schema.primary_key,
                "column_count": len(schema.columns),
                "procedures": self._procedures.get(key, {}),
            }
            for key, schema in sorted(self._schemas.items())
        ]

    def filter_by_prefix(self, prefix: str) -> list[str]:
        prefix_lower = prefix.lower()
        return [
            key
            for key, schema in self._schemas.items()
            if schema.table_name.lower().startswith(prefix_lower)
            or key.lower().startswith(prefix_lower)
        ]
