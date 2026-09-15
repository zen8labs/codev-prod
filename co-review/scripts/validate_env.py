#!/usr/bin/env python3
"""Fail-fast stack config check for Co-review (stdlib only).

Reads a Compose-style .env file, expands ${VAR} / $VAR from the same file,
then validates required keys and formats. Exit 1 if anything is missing
or malformed so Compose is not started half-configured.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Mapping
from urllib.parse import urlparse

_LINE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$")
_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
_TRUTHY = frozenset({"1", "true", "yes", "on"})
_FALSEY = frozenset({"0", "false", "no", "off"})
_BOOL_KEYS = frozenset(
    {
        "SSO_AUTH_DISABLED",
        "SSO_DEBUG",
        "GITHUB_EXTERNAL",
        "GITLAB_EXTERNAL",
        "BITBUCKET_EXTERNAL",
        "AZUREDEVOPS_EXTERNAL",
        "BACKUP_PITR_ENABLED",
        "ORG_SCOPE_GIT_PROVIDERS",
        "ORG_SCOPE_LLM_PROVIDERS",
        "ORG_SCOPE_PEER_GRANTS",
        "DEVLAKE_API_VERIFY_TLS",
    }
)
_HTTP_OPTIONAL = (
    "OPENAI_BASE_URL",
    "PR_AGENT_API_URL",
    "SSO_BASE_URL",
    "DASHBOARD_PUBLIC_BASE_URL",
    "AGENT_EXTERNAL_URL",
    "AGENT_EXTERNAL_CALLBACK_URL",
    "AGENT_EXTERNAL_COMPLETION_CALLBACK_URL",
    "DEVLAKE_API_BASE_URL",
    "DEVLAKE_GRAFANA_ROOT_URL",
)
_EXTERNAL_FLAGS = (
    "GITHUB_EXTERNAL",
    "GITLAB_EXTERNAL",
    "BITBUCKET_EXTERNAL",
    "AZUREDEVOPS_EXTERNAL",
)


def _strip_value(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    text = path.read_text(encoding="utf-8")
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = _LINE.match(line)
        if not match:
            continue
        values[match.group(1)] = _strip_value(match.group(2))
    return values


def expand_env(values: Mapping[str, str]) -> dict[str, str]:
    expanded = dict(values)

    def replace(match: re.Match[str]) -> str:
        key = match.group(1) or match.group(2)
        return expanded.get(key, "")

    for _ in range(8):
        changed = False
        for key, value in list(expanded.items()):
            new = _REF.sub(replace, value)
            if new != value:
                expanded[key] = new
                changed = True
        if not changed:
            break
    return expanded


def _is_truthy(values: Mapping[str, str], name: str) -> bool:
    return values.get(name, "").strip().lower() in _TRUTHY


def _is_postgres_url(value: str) -> bool:
    v = value.strip().lower()
    return v.startswith(("postgres://", "postgresql://", "postgresql+"))


def _is_http_url(value: str) -> bool:
    parsed = urlparse(value.strip())
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def validate_stack(
    values: Mapping[str, str],
    *,
    include_devlake: bool = False,
    include_external_agent: bool = False,
) -> list[str]:
    """Return error strings. Empty list means the stack env is valid."""
    errors: list[str] = []

    def require(name: str) -> None:
        if not values.get(name, "").strip():
            errors.append(f"missing required {name}")

    require("POSTGRES_USER")
    require("POSTGRES_PASSWORD")
    require("POSTGRES_DB")
    require("DATABASE_URL")
    require("GIT_PROVIDER_CREDENTIALS_ENCRYPTION_KEY")

    if not _is_truthy(values, "SSO_AUTH_DISABLED"):
        require("SSO_SESSION_SECRET")

    database_url = values.get("DATABASE_URL", "").strip()
    if database_url and not _is_postgres_url(database_url):
        errors.append("DATABASE_URL must be a postgres:// or postgresql:// URL")

    for name in _HTTP_OPTIONAL:
        value = values.get(name, "").strip()
        if value and not _is_http_url(value):
            errors.append(f"{name} must be an http(s) URL")

    for name in _BOOL_KEYS:
        value = values.get(name, "").strip()
        if value and value.lower() not in _TRUTHY | _FALSEY:
            errors.append(f"{name} must be a boolean (true/false)")

    if any(_is_truthy(values, flag) for flag in _EXTERNAL_FLAGS):
        if not values.get("AGENT_EXTERNAL_URL", "").strip():
            errors.append("missing required AGENT_EXTERNAL_URL (an *_EXTERNAL flag is true)")
        elif not _is_http_url(values.get("AGENT_EXTERNAL_URL", "")):
            errors.append("AGENT_EXTERNAL_URL must be an http(s) URL")

    if include_devlake:
        require("ENCRYPTION_SECRET")
        require("DEVLAKE_MYSQL_ROOT_PASSWORD")

    if include_external_agent:
        if not values.get("AGENT_EXTERNAL_URL", "").strip():
            errors.append("missing required AGENT_EXTERNAL_URL (external agent enabled)")

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate Co-review .env before Compose up")
    parser.add_argument(
        "--env-file",
        type=Path,
        default=Path(".env"),
        help="Path to .env (default: .env)",
    )
    parser.add_argument(
        "--with-devlake",
        action="store_true",
        help="Require DevLake secrets (ENCRYPTION_SECRET, MySQL password)",
    )
    parser.add_argument(
        "--with-external-agent",
        action="store_true",
        help="Require AGENT_EXTERNAL_URL for Open-Hand",
    )
    args = parser.parse_args(argv)

    env_file = args.env_file
    if not env_file.is_file():
        print(f"[fatal] env file not found: {env_file}", file=sys.stderr)
        print("Copy .env.example to .env and fill required values.", file=sys.stderr)
        return 1

    values = expand_env(load_env_file(env_file))
    errors = validate_stack(
        values,
        include_devlake=args.with_devlake,
        include_external_agent=args.with_external_agent,
    )
    if errors:
        print("[fatal] configuration invalid:", file=sys.stderr)
        for item in errors:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"[ok] environment valid ({env_file})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
