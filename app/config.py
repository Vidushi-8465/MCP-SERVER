import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")


@dataclass(frozen=True)
class DatabaseConfig:
    host: str
    port: int
    database: str
    user: str
    password: str
    schema: str
    ne_schema: str | None = None
    ne_table_prefix: str = "ne"
    ne_tables: list[str] = field(default_factory=list)
    auto_setup_all_tables: bool = False
    auto_setup_ne_tables: bool = False

    @property
    def dsn(self) -> str: # Data Source Name
        url = os.getenv("DATABASE_URL")
        if url:
            return url
        return (
            f"postgresql://{self.user}:{self.password}"
            f"@{self.host}:{self.port}/{self.database}"
        )


def _parse_ne_tables(raw: str | None) -> list[str]:
    if not raw:
        return []
    return [name.strip() for name in raw.split(",") if name.strip()]


def load_config() -> DatabaseConfig:
    return DatabaseConfig(
        host=os.getenv("DB_HOST", "localhost"),
        port=int(os.getenv("DB_PORT", "5432")),
        database=os.getenv("DB_NAME", "postgres"),
        user=os.getenv("DB_USER", "postgres"),
        password=os.getenv("DB_PASSWORD", ""),
        schema=os.getenv("DB_SCHEMA", "public"),
        ne_schema=os.getenv("NE_SCHEMA") or None,
        ne_table_prefix=os.getenv("NE_TABLE_PREFIX", "ne"),
        ne_tables=_parse_ne_tables(os.getenv("NE_TABLES")),
        auto_setup_all_tables=os.getenv("AUTO_SETUP_ALL_TABLES", "").lower()
        in ("1", "true", "yes"),
        auto_setup_ne_tables=os.getenv("AUTO_SETUP_NE_TABLES", "").lower()
        in ("1", "true", "yes"),
    )
