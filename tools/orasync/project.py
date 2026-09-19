"""Catalogue des scripts du projet et operations de haut niveau."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

from .config import ConfigError, Settings
from .db import connect
from .sqlplus import RunStats, SqlPlusRunner

LOGGER = logging.getLogger("orasync")


@dataclass(frozen=True)
class ScriptSpec:
    filename: str
    profile: str
    description: str

    def path(self, settings: Settings) -> Path:
        return settings.script_path(self.filename)


CORE_SCRIPTS: tuple[ScriptSpec, ...] = (
    ScriptSpec("01_sync_config_tables.sql", "admin", "Tables de configuration"),
    ScriptSpec("02_sync_log_tables.sql", "admin", "Tables de journalisation"),
    ScriptSpec("03_sync_package_spec.sql", "admin", "Specification du package"),
    ScriptSpec("04_sync_package_body.sql", "admin", "Corps du package"),
)

MIGRATION_SCRIPTS = (
    ScriptSpec("08_migration_v2.sql", "admin", "Migration idempotente v1 -> v2/v3"),
    ScriptSpec("10_migration_v5.sql", "admin", "Migration idempotente v5 (auto-reparation FK/cycles/auto-creation)"),
)
SAMPLE_SCRIPT = ScriptSpec(
    "05_sample_data_and_config.sql", "multi", "Donnees et configuration d'exemple"
)
HARNESS_SCRIPT = ScriptSpec(
    "07_test_harness.sql", "admin", "Harnais de tests (non destructif)"
)
SCENARIOS_SCRIPT = ScriptSpec(
    "06_test_scenarios.sql", "multi", "Scenarios de test de bout en bout"
)
MODE_DEMO_SCRIPT = ScriptSpec(
    "09_test_sync_mode.sql", "admin", "Demonstration des modes de synchronisation"
)

_SECTION_PATTERN = re.compile(r"^--\s*PARTIE\s+(A|B|CONFIG)\b.*$", re.IGNORECASE | re.MULTILINE)
_SECTION_PROFILES = {"A": "schema_a", "B": "schema_b", "CONFIG": "admin"}
_LINK_PLACEHOLDER = "<UTILISATEUR_UTILISE_PAR_SYNC_LINK_B>"


def _report_stats(label: str, stats: RunStats) -> None:
    LOGGER.info(
        "%s : %d instruction(s), %d requete(s), %d ligne(s), "
        "%d erreur(s), %d ignoree(s)",
        label,
        stats.statements,
        stats.selects,
        stats.rows,
        stats.errors,
        stats.tolerated,
    )


def run_scripts(
    settings: Settings,
    profile_name: str,
    scripts: Sequence[ScriptSpec | str],
    *,
    stop_on_error: bool = True,
    tolerate_idempotent_errors: bool = False,
    dry_run: bool = False,
) -> RunStats:
    """Execute une liste de scripts sur une meme connexion."""

    total = RunStats()
    resolved: list[tuple[str, Path]] = []
    for script in scripts:
        if isinstance(script, ScriptSpec):
            resolved.append((script.filename, script.path(settings)))
        else:
            resolved.append((str(script), settings.script_path(script)))

    missing = [str(path) for _, path in resolved if not path.is_file()]
    if missing:
        raise ConfigError("Script(s) introuvable(s) : " + ", ".join(missing))

    if dry_run:
        for name, path in resolved:
            LOGGER.info("[dry-run] profil=%s script=%s", profile_name, path)
        return total

    with connect(settings.profile(profile_name), settings) as connection:
        for name, path in resolved:
            runner = SqlPlusRunner(
                connection,
                source=str(path),
                stop_on_error=stop_on_error,
                tolerate_idempotent_errors=tolerate_idempotent_errors,
            )
            stats = runner.run_file(path)
            total.merge(stats)
            LOGGER.info("  - %s : OK", name)
    _report_stats(profile_name, total)
    return total


def install_core(
    settings: Settings, *, with_migration: bool = True, dry_run: bool = False
) -> RunStats:
    scripts: list[ScriptSpec] = list(CORE_SCRIPTS)
    if with_migration:
        scripts.extend(MIGRATION_SCRIPTS)
    return run_scripts(
        settings,
        "admin",
        scripts,
        tolerate_idempotent_errors=True,
        dry_run=dry_run,
    )


def migrate(settings: Settings, *, dry_run: bool = False) -> RunStats:
    return run_scripts(
        settings,
        "admin",
        [*MIGRATION_SCRIPTS],
        tolerate_idempotent_errors=True,
        dry_run=dry_run,
    )


def run_harness(settings: Settings, *, dry_run: bool = False) -> RunStats:
    return run_scripts(settings, "admin", [HARNESS_SCRIPT], dry_run=dry_run)


def _split_sample(text: str) -> list[tuple[str, str]]:
    matches = list(_SECTION_PATTERN.finditer(text))
    if not matches:
        return [("admin", text)]
    sections: list[tuple[str, str]] = []
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        profile = _SECTION_PROFILES[match.group(1).upper()]
        sections.append((profile, text[start:end]))
    return sections


def run_sample(
    settings: Settings,
    *,
    link_user: str | None = None,
    dry_run: bool = False,
) -> RunStats:
    path = SAMPLE_SCRIPT.path(settings)
    if not path.is_file():
        raise ConfigError(f"Script introuvable : {path}")

    from .db import session
    from .sqlplus import SqlPlusRunner

    effective_link_user = link_user or settings.link_user or settings.profile("schema_b").user
    if not effective_link_user:
        raise ConfigError(
            "Utilisateur du database link inconnu : renseignez ORASYNC_LINK_USER "
            "ou le profil schema_b."
        )

    text = path.read_text(encoding="utf-8", errors="replace")
    text = text.replace(_LINK_PLACEHOLDER, effective_link_user)
    sections = _split_sample(text)

    total = RunStats()
    if dry_run:
        for profile, section in sections:
            LOGGER.info(
                "[dry-run] profil=%s section=%d caracteres (%s)",
                profile,
                len(section),
                SAMPLE_SCRIPT.filename,
            )
        return total

    for profile, section in sections:
        LOGGER.info("section %s (%s) ...", SAMPLE_SCRIPT.filename, profile)
        with session(settings, profile) as connection:
            runner = SqlPlusRunner(
                connection,
                source=f"{SAMPLE_SCRIPT.filename}:{profile}",
                tolerate_idempotent_errors=True,
            )
            stats = runner.run_text(section)
        total.merge(stats)
    _report_stats(SAMPLE_SCRIPT.filename, total)
    return total


def run_sql_file(
    settings: Settings,
    filename: str,
    profile_name: str,
    *,
    stop_on_error: bool = True,
    tolerate_idempotent_errors: bool = False,
    dry_run: bool = False,
) -> RunStats:
    return run_scripts(
        settings,
        profile_name,
        [filename],
        stop_on_error=stop_on_error,
        tolerate_idempotent_errors=tolerate_idempotent_errors,
        dry_run=dry_run,
    )


def fetch_status(settings: Settings, limit: int = 10) -> list[tuple]:
    """Retourne les dernieres executions enregistrees dans SYNC_RUN_HEADER."""

    from .db import session

    query = (
        "SELECT run_id, run_type, status, start_date, "
        "total_tables, tables_success, tables_failed "
        "FROM sync_run_header ORDER BY run_id DESC FETCH FIRST :limit ROWS ONLY"
    )
    with session(settings, "admin") as connection:
        with connection.cursor() as cursor:
            cursor.execute(query, limit=limit)
            return cursor.fetchall()


def check_profiles(settings: Settings) -> list[tuple[str, bool, str]]:
    """Teste chaque profil configure ; retourne (nom, ok, detail)."""

    from .db import server_info

    results: list[tuple[str, bool, str]] = []
    for name, profile in settings.profiles.items():
        if not profile.defined:
            results.append((name, False, f"non configure ({profile.env_hint()})"))
            continue
        try:
            with connect(profile, settings) as connection:
                info = server_info(connection)
            detail = (
                f"{info.get('user')}@{info.get('db_name')}"
                f"/{info.get('container')} (Oracle {info.get('version')})"
            )
            results.append((name, True, detail))
        except Exception as exc:  # noqa: BLE001 - diagnostic : on n'arrete pas le check
            results.append((name, False, str(exc)))
    return results


def installed_objects(settings: Settings) -> dict[str, int]:
    """Compte les objets du package et des tables SYNC_* (diagnostic)."""

    from .db import session

    counts: dict[str, int] = {}
    with session(settings, "admin") as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT object_type, COUNT(*) FROM user_objects "
                "WHERE object_name LIKE 'SYNC\\_%' ESCAPE '\\' "
                "GROUP BY object_type"
            )
            for object_type, count in cursor.fetchall():
                counts[object_type] = count
    return counts


def iter_scripts() -> Iterable[ScriptSpec]:
    yield from CORE_SCRIPTS
    yield from MIGRATION_SCRIPTS
    yield SAMPLE_SCRIPT
    yield HARNESS_SCRIPT
    yield SCENARIOS_SCRIPT
    yield MODE_DEMO_SCRIPT
