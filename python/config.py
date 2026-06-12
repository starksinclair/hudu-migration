import os
from pathlib import Path

from .types.common import InstanceConfig, Stats


def _load_env_file() -> None:
    """Parse .env from the repo root and populate os.environ (stdlib only)."""
    env_path = Path(__file__).parent.parent / ".env"
    if not env_path.exists():
        return
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


def _require_env(key: str) -> str:
    value = os.environ.get(key)
    if not value:
        raise EnvironmentError(f"Missing required environment variable: {key}")
    return value


def load_config() -> InstanceConfig:
    _load_env_file()
    return InstanceConfig(
        source_api_key=_require_env("SOURCE_API_KEY"),
        source_base_url=_require_env("SOURCE_BASE_URL").rstrip("/"),
        target_api_key=_require_env("TARGET_API_KEY"),
        target_base_url=_require_env("TARGET_BASE_URL").rstrip("/"),
        max_file_size_mb=int(os.environ.get("MAX_FILE_SIZE_MB", "100")),
        skip_asset_migration=os.environ.get("SKIP_ASSET_MIGRATION", "false").lower() == "true",
    )


def create_empty_stats() -> Stats:
    return Stats()
