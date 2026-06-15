from __future__ import annotations


def make_table_ref(schema_name: str, table_name: str) -> str:
    return f"{schema_name}.{table_name}"


def parse_table_ref(table_ref: str, default_schema: str) -> tuple[str, str]:
    if "." in table_ref:
        schema_name, table_name = table_ref.split(".", 1)
        return schema_name, table_name
    return default_schema, table_ref


def resolve_registry_key(table_ref: str, default_schema: str) -> str:
    schema_name, table_name = parse_table_ref(table_ref, default_schema)
    return make_table_ref(schema_name, table_name)
