"""Acces base de donnees via python-oracledb (mode thin)."""

from __future__ import annotations

import logging
from contextlib import contextmanager
from typing import Iterator

import oracledb

from .config import ConfigError, DbProfile, Settings

LOGGER = logging.getLogger("orasync")


def _auth_mode(role: str | None) -> int | None:
    if not role:
        return None
    attribute = f"AUTH_MODE_{role.strip().upper()}"
    mode = getattr(oracledb, attribute, None)
    if mode is None:
        raise ConfigError(
            f"Role Oracle inconnu : '{role}'. Valeurs possibles : SYSDBA, SYSOPER."
        )
    return mode


def connect(profile: DbProfile, settings: Settings) -> oracledb.Connection:
    """Ouvre une connexion pour le profil donne."""

    if not profile.defined:
        raise ConfigError(
            f"Profil '{profile.name}' incomplet. Renseignez : {profile.env_hint()} "
            f"(fichier {settings.env_file or '.env'})."
        )

    kwargs: dict = {
        "user": profile.user,
        "password": profile.password,
        "dsn": profile.dsn,
    }
    mode = _auth_mode(profile.role)
    if mode is not None:
        kwargs["mode"] = mode

    LOGGER.debug(
        "connexion profil=%s user=%s dsn=%s role=%s",
        profile.name,
        profile.user,
        profile.dsn,
        profile.role or "-",
    )
    try:
        connection = oracledb.connect(**kwargs)
    except oracledb.Error as exc:
        raise ConfigError(
            f"Connexion impossible pour le profil '{profile.name}' "
            f"({profile.user}@{profile.dsn}) : {exc}"
        ) from exc
    return connection


@contextmanager
def session(
    settings: Settings, profile_name: str
) -> Iterator[oracledb.Connection]:
    """Context manager : connexion + fermeture systematique."""

    connection = connect(settings.profile(profile_name), settings)
    try:
        yield connection
    finally:
        try:
            connection.close()
        except oracledb.Error:  # pragma: no cover
            pass


def server_info(connection: oracledb.Connection) -> dict[str, str]:
    """Retourne des informations de session (version, utilisateur, schema)."""

    info: dict[str, str] = {}
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT version FROM product_component_version "
            "WHERE UPPER(product) LIKE '%DATABASE%' "
            "AND UPPER(product) NOT LIKE '%CLIENT%' "
            "FETCH FIRST 1 ROW ONLY"
        )
        row = cursor.fetchone()
        info["version"] = str(row[0]) if row else "?"
        cursor.execute(
            "SELECT USER, SYS_CONTEXT('USERENV', 'DB_NAME'), "
            "SYS_CONTEXT('USERENV', 'CON_NAME') FROM dual"
        )
        row = cursor.fetchone()
        if row:
            info["user"] = row[0] or ""
            info["db_name"] = row[1] or ""
            info["container"] = row[2] or ""
    return info
