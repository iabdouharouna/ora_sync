"""Synchro niveau schéma (stats Oracle) — patch & run.

Détermine les tables en écart de volumétrie `NUM_ROWS` (périmètre : tables
communes présentes des deux côtés) via le rapport v6 `REPORT_COUNTS_GAP`,
puis synchronise ces tables (dry run systématique ; run réel uniquement sur
flag explicite). L'ensemble s'exécute sous PATCH TEMPORAIRE des constantes
compilées C_SCHEMA_A/B (Annexe C de 11_PROCEDURE) avec restauration garantie
en `finally`, même en cas d'erreur.

Convention v6 : DIFF = NUM_ROWS_B - NUM_ROWS_A (signe + : B a plus de lignes
que A) ; DIFF_PCT sur la valeur absolue, base GREATEST(A, B). Les tables
`NO_STATS_*` (stats absentes d'un côté au moins) sont exclues de la synchro
(impossible de juger) mais comptées et signalées.

Profil par défaut (décision utilisateur) : direction BIDIRECTIONAL (chaque
côté reçoit les lignes qui lui manquent), mode INSERT seul (aucune valeur
existante n'est écrasée), conflits ERROR_ON_CONFLICT (tableau signalé, non
réparé), priorité 10, exclusions d'audit standard.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

import oracledb

from .config import ConfigError, Settings

#: Colonnes d'audit exclues par défaut (défaut partagé script 12).
DEFAULT_EXCLUSIONS = (
    "DATE_CREATE,DATE_MODIF,USER_MODIF,DATE_CREATION,CREATED_DATE,UPDATED_DATE"
)

_PATTERN_A = re.compile(r"(C_SCHEMA_A\s+CONSTANT VARCHAR2\(128\) := )'[^']*'")
_PATTERN_B = re.compile(r"(C_SCHEMA_B\s+CONSTANT VARCHAR2\(128\) := )'[^']*'")


@dataclass
class SchemaSyncResult:
    """Résultat complet d'une exécution schema-sync."""

    gap_id: int | None = None
    header: dict | None = None
    gap_tables: list[dict] = field(default_factory=list)
    no_stats: list[dict] = field(default_factory=list)
    config_kept: list[str] = field(default_factory=list)
    jobs: tuple[str, str] | None = None
    dry_run_id: int | None = None
    dry_header: dict | None = None
    dry_rows: list[dict] = field(default_factory=list)
    real_run_id: int | None = None
    real_header: dict | None = None
    real_rows: list[dict] = field(default_factory=list)


def _patched(text: str, schema_a: str, schema_b: str) -> str:
    """Substitue les constantes d'ancrage C_SCHEMA_A/B (Annexe C)."""
    text = _PATTERN_A.sub(lambda m: m.group(1) + "'" + schema_a + "'", text)
    text = _PATTERN_B.sub(lambda m: m.group(1) + "'" + schema_b + "'", text)
    return text


def _collect_stats(
    connection: Any, schema_a: str, schema_b: str, wait_timeout: int
) -> tuple[str, str]:
    """Collecte asynchrone des stats (SUBMIT_STATS_JOBS) + attente de fin."""
    with connection.cursor() as cursor:
        got_a = cursor.var(str)
        got_b = cursor.var(str)
        cursor.execute(
            """
            DECLARE
                v_a  VARCHAR2(128) := NVL(:sa, PKG_SCHEMA_SYNC.C_SCHEMA_A);
                v_b  VARCHAR2(128) := NVL(:sb, PKG_SCHEMA_SYNC.C_SCHEMA_B);
                v_ja VARCHAR2(128);
                v_jb VARCHAR2(128);
            BEGIN
                PKG_SCHEMA_SYNC.SUBMIT_STATS_JOBS(
                    p_schema_a   => v_a,
                    p_schema_b   => v_b,
                    p_job_name_a => v_ja,
                    p_job_name_b => v_jb);
                :ja := v_ja;
                :jb := v_jb;
            END;""",
            sa=schema_a,
            sb=schema_b,
            ja=got_a,
            jb=got_b,
        )
        job_a, job_b = got_a.getvalue(), got_b.getvalue()
        got_ok = cursor.var(str)
        cursor.execute(
            """
            DECLARE
                v_ok BOOLEAN;
            BEGIN
                PKG_SCHEMA_SYNC.WAIT_FOR_STATS_JOBS(
                    p_job_name_a    => :ja,
                    p_job_name_b    => :jb,
                    p_timeout_sec   => :timeout,
                    p_all_succeeded => v_ok);
                :ok := CASE WHEN v_ok THEN 'Y' ELSE 'N' END;
            END;""",
            ja=job_a,
            jb=job_b,
            timeout=wait_timeout,
            ok=got_ok,
        )
        if got_ok.getvalue() != "Y":
            raise ConfigError(
                "Collecte des stats sans succes sur l'un des schemas "
                f"(jobs {job_a} / {job_b}) - verifier USER_SCHEDULER_JOB_RUN_DETAILS."
            )
    return job_a, job_b


def _report_gap(
    connection: Any, schema_a: str, schema_b: str, max_age_hours: float | None
) -> tuple[int | None, dict | None, list[dict]]:
    """Rapport v6 persistant (REPORT_COUNTS_GAP) + REF CURSOR entête/détail."""
    with connection.cursor() as cursor:
        got_gap = cursor.var(int)
        got_header = cursor.var(oracledb.CURSOR)
        got_detail = cursor.var(oracledb.CURSOR)
        cursor.execute(
            """
            DECLARE
                v_a   VARCHAR2(128) := NVL(:sa, PKG_SCHEMA_SYNC.C_SCHEMA_A);
                v_b   VARCHAR2(128) := NVL(:sb, PKG_SCHEMA_SYNC.C_SCHEMA_B);
                v_gap NUMBER;
                v_h   SYS_REFCURSOR;
                v_d   SYS_REFCURSOR;
            BEGIN
                PKG_SCHEMA_SYNC.REPORT_COUNTS_GAP(
                    p_schema_a      => v_a,
                    p_schema_b      => v_b,
                    p_max_age_hours => :mh,
                    p_gap_id        => v_gap,
                    p_header_cursor => v_h,
                    p_detail_cursor => v_d);
                :gap := v_gap;
                :hdr := v_h;
                :dtl := v_d;
            END;""",
            sa=schema_a,
            sb=schema_b,
            mh=max_age_hours,
            gap=got_gap,
            hdr=got_header,
            dtl=got_detail,
        )
        gap_id = got_gap.getvalue()
        header = None
        hc = got_header.getvalue()
        row = hc.fetchone()
        if row:
            header = dict(
                zip(
                    [
                        "gap_id", "collect_date", "job_name_a", "job_name_b",
                        "stats_date_a", "stats_date_b", "total_tables",
                        "tables_ok", "tables_gap", "tables_no_stats_a",
                        "tables_no_stats_b", "executed_by",
                    ],
                    row,
                )
            )
        detail: list[dict] = []
        dc = got_detail.getvalue()
        columns = [
            "detail_id", "gap_id", "table_name", "num_rows_a", "num_rows_b",
            "diff", "diff_pct", "last_analyzed_a", "last_analyzed_b",
            "gap_flag",
        ]
        while True:
            row = dc.fetchone()
            if row is None:
                break
            detail.append(dict(zip(columns, row)))
    return gap_id, header, detail


def _configure_tables(
    connection: Any,
    schema_a: str,
    table_names: list[str],
    *,
    direction: str,
    sync_mode: str,
    conflicts: str,
    priority: int,
    exclusions: str,
) -> list[str]:
    """Config idempotente des tables en écart (l'existant n'est jamais écrasé)
    + exclusions d'audit présentes côté A. Retourne les tables déjà configurées.
    """
    kept: list[str] = []
    columns = [c.strip().upper() for c in exclusions.split(",") if c.strip()]
    with connection.cursor() as cursor:
        for name in table_names:
            cursor.execute(
                """
                INSERT INTO SYNC_TABLE_CONFIG (TABLE_NAME, ENABLED, SYNC_DIRECTION,
                                               SYNC_MODE, CONFLICT_STRATEGY, PRIORITY)
                SELECT :1, 'Y', :2, :3, :4, :5 FROM DUAL
                 WHERE NOT EXISTS (SELECT 1 FROM SYNC_TABLE_CONFIG WHERE TABLE_NAME = :1)
                """,
                [name, direction, sync_mode, conflicts, priority, name],
            )
            if cursor.rowcount == 0:
                kept.append(name)
            for column in columns:
                cursor.execute(
                    """
                    INSERT INTO SYNC_COLUMN_CONFIG (TABLE_NAME, COLUMN_NAME, SYNC_ENABLED)
                    SELECT :1, :2, 'N' FROM DUAL
                     WHERE NOT EXISTS (
                           SELECT 1 FROM SYNC_COLUMN_CONFIG
                            WHERE TABLE_NAME = :3 AND COLUMN_NAME = :4)
                       AND EXISTS (SELECT 1 FROM all_tab_columns
                                    WHERE owner = :5 AND table_name = :6 AND column_name = :7)
                    """,
                    [name, column, name, column, schema_a, name, column],
                )
        connection.commit()
    return kept


def _sync_tables(connection: Any, table_names: list[str], dry_run: bool) -> int:
    """Invoque SYNC_TABLES sur la liste (dry ou réel) et rend le run_id."""
    literal = ",".join("'" + name.replace("'", "''") + "'" for name in table_names)
    flag = "TRUE" if dry_run else "FALSE"
    with connection.cursor() as cursor:
        got = cursor.var(int)
        cursor.execute(
            f"""
            DECLARE
                v_list PKG_SCHEMA_SYNC.t_tab_name_list :=
                    PKG_SCHEMA_SYNC.t_tab_name_list({literal});
                v_run  NUMBER;
            BEGIN
                PKG_SCHEMA_SYNC.SYNC_TABLES(
                    p_table_list => v_list,
                    p_dry_run    => {flag},
                    p_error_mode => PKG_SCHEMA_SYNC.C_ERROR_MODE_CONTINUE,
                    p_run_id     => v_run);
                :rid := v_run;
            END;""",
            rid=got,
        )
        return got.getvalue()


def _run_header(connection: Any, run_id: int) -> dict | None:
    """Synthèse du run (SYNC_RUN_HEADER)."""
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT run_id, run_type, status, dry_run, error_mode, start_date,
                   total_tables, tables_excluded, tables_success, tables_conflict,
                   tables_failed, executed_by
              FROM sync_run_header WHERE run_id = :1
            """,
            [run_id],
        )
        row = cursor.fetchone()
    if row is None:
        return None
    return dict(
        zip(
            [
                "run_id", "run_type", "status", "dry_run", "error_mode",
                "start_date", "total_tables", "tables_excluded",
                "tables_success", "tables_conflict", "tables_failed",
                "executed_by",
            ],
            row,
        )
    )


def _run_log(connection: Any, run_id: int) -> list[dict]:
    """Détail par table d'un run (SYNC_LOG)."""
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT table_name, status, sync_mode,
                   rows_inserted_a_to_b, rows_inserted_b_to_a,
                   rows_updated_a_to_b, rows_updated_b_to_a,
                   conflict_count, error_count, error_message
              FROM sync_log WHERE run_id = :1 ORDER BY table_name
            """,
            [run_id],
        )
        columns = [
            "table_name", "status", "sync_mode",
            "rows_inserted_a_to_b", "rows_inserted_b_to_a",
            "rows_updated_a_to_b", "rows_updated_b_to_a",
            "conflict_count", "error_count", "error_message",
        ]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]


def schema_sync(
    settings: Settings,
    *,
    schema_a: str,
    schema_b: str,
    direction: str = "BIDIRECTIONAL",
    sync_mode: str = "INSERT",
    conflicts: str = "ERROR_ON_CONFLICT",
    priority: int = 10,
    exclusions: str = DEFAULT_EXCLUSIONS,
    collect: bool = False,
    max_age_hours: float | None = None,
    wait_timeout: int = 3600,
    max_tables: int | None = None,
    min_diff_pct: float | None = None,
    real: bool = False,
) -> SchemaSyncResult:
    """Patch & run d'une synchro niveau schéma (voir docstring du module).

    Workflow : patch temporaire des constantes (Annexe C) → collecte optionnelle
    des stats → rapport v6 (écarts NUM_ROWS) → filtres optionnels → config
    idempotente des tables en écart → dry run systématique → run réel si real.
    Restauration du package en mode test garantie en `finally`.
    """
    from .db import session
    from .sqlplus import SqlPlusRunner

    spec = (settings.scripts_dir / "03_sync_package_spec.sql").read_text(
        encoding="utf-8"
    )
    body = (settings.scripts_dir / "04_sync_package_body.sql").read_text(
        encoding="utf-8"
    )
    result = SchemaSyncResult()

    with session(settings, "admin") as connection:
        try:
            # 1) PATCH TEMPORAIRE (Annexe C) — constantes d'ancrage = cibles.
            SqlPlusRunner(
                connection, source="spec (patch)", emit=print
            ).run_text(_patched(spec, schema_a, schema_b))
            SqlPlusRunner(connection, source="corps (patch)", emit=print).run_text(body)

            # 2) STATS — collecte explicite optionnelle (défaut : réutiliser).
            if collect:
                result.jobs = _collect_stats(
                    connection, schema_a, schema_b, wait_timeout
                )

            # 3) RAPPORT v6 — périmètre = tables communes, écarts NUM_ROWS.
            gap_id, header, detail = _report_gap(
                connection, schema_a, schema_b, max_age_hours
            )
            result.gap_id = gap_id
            result.header = header

            diff = [row for row in detail if row["gap_flag"] == "DIFF"]
            result.no_stats = [
                row
                for row in detail
                if str(row["gap_flag"] or "").startswith("NO_STATS")
            ]
            # Tri |DIFF| décroissant puis filtres optionnels.
            diff.sort(key=lambda row: abs(row["diff"] or 0), reverse=True)
            if min_diff_pct is not None:
                diff = [
                    row
                    for row in diff
                    if row["diff_pct"] is not None
                    and row["diff_pct"] >= min_diff_pct
                ]
            if max_tables is not None:
                diff = diff[: max(max_tables, 0)]
            result.gap_tables = diff

            tables = [row["table_name"] for row in diff]
            if not tables:
                return result  # rien à synchroniser (finally restaure)

            # 4) CONFIG idempotente des tables en écart.
            result.config_kept = _configure_tables(
                connection,
                schema_a,
                tables,
                direction=direction,
                sync_mode=sync_mode,
                conflicts=conflicts,
                priority=priority,
                exclusions=exclusions,
            )

            # 5) DRY RUN — systématique.
            result.dry_run_id = _sync_tables(connection, tables, dry_run=True)
            result.dry_header = _run_header(connection, result.dry_run_id)
            result.dry_rows = _run_log(connection, result.dry_run_id)

            # 6) RUN RÉEL — uniquement sur flag explicite.
            if real:
                result.real_run_id = _sync_tables(connection, tables, dry_run=False)
                result.real_header = _run_header(connection, result.real_run_id)
                result.real_rows = _run_log(connection, result.real_run_id)
        finally:
            # RESTAURATION systématique du mode test (Annexe C).
            SqlPlusRunner(
                connection, source="spec (restauration)", emit=print
            ).run_text(spec)
            SqlPlusRunner(connection, source="corps (restauration)", emit=print).run_text(
                body
            )

    return result