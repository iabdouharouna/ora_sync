"""Chargement de la configuration (variables d'environnement / fichier .env)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_PROFILES = "admin,schema_a,schema_b,sys"
ROLE_DEFAULTS = {"sys": "SYSDBA"}


class ConfigError(RuntimeError):
    """Erreur de configuration (variable manquante ou invalide)."""


@dataclass(frozen=True)
class DbProfile:
    """Parametres de connexion d'un profil."""

    name: str
    user: str = ""
    password: str = ""
    dsn: str = ""
    role: str | None = None

    @property
    def defined(self) -> bool:
        return bool(self.user and self.password and self.dsn)

    def env_hint(self) -> str:
        prefix = f"ORASYNC_{self.name.upper()}"
        return (
            f"{prefix}_USER, {prefix}_PASSWORD, {prefix}_DSN "
            f"(ou ORASYNC_DSN)"
        )


@dataclass
class Settings:
    """Configuration complete de l'outil."""

    repo_root: Path
    scripts_dir: Path
    profiles: dict[str, DbProfile] = field(default_factory=dict)
    link_name: str = "SYNC_LINK_B"
    link_user: str = ""
    env_file: Path | None = None

    def profile(self, name: str) -> DbProfile:
        key = name.strip().lower()
        if key not in self.profiles:
            raise ConfigError(
                f"Profil inconnu : '{name}'. Profils disponibles : "
                f"{', '.join(sorted(self.profiles))}"
            )
        return self.profiles[key]

    def script_path(self, filename: str) -> Path:
        path = Path(filename)
        if not path.is_absolute():
            path = self.scripts_dir / path
        return path


def _load_dotenv(path: Path) -> None:
    """Charge un fichier .env minimaliste sans ecraser l'environnement reel."""

    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower().startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            os.environ.setdefault(key, value)


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    if value is None:
        return default
    value = value.strip()
    return value if value else default


def from_env(repo_root: Path | None = None, env_file: str | None = None) -> Settings:
    """Construit la configuration a partir de l'environnement et du .env."""

    repo_root = (repo_root or Path(__file__).resolve().parents[2]).resolve()

    explicit = env_file or os.environ.get("ORASYNC_ENV_FILE")
    dotenv_path = (
        Path(explicit).expanduser()
        if explicit
        else repo_root / ".env"
    )
    if not dotenv_path.is_absolute():
        dotenv_path = repo_root / dotenv_path
    _load_dotenv(dotenv_path)

    common_dsn = _env("ORASYNC_DSN", "")

    names_raw = _env("ORASYNC_PROFILES", DEFAULT_PROFILES) or DEFAULT_PROFILES
    names = [item.strip().lower() for item in names_raw.split(",") if item.strip()]

    profiles: dict[str, DbProfile] = {}
    for name in names:
        prefix = f"ORASYNC_{name.upper()}"
        role = _env(f"{prefix}_ROLE") or ROLE_DEFAULTS.get(name)
        profiles[name] = DbProfile(
            name=name,
            user=_env(f"{prefix}_USER", "") or "",
            password=_env(f"{prefix}_PASSWORD", "") or "",
            dsn=_env(f"{prefix}_DSN") or common_dsn or "",
            role=role,
        )

    scripts_dir = _env("ORASYNC_SCRIPTS_DIR")
    scripts_path = Path(scripts_dir).expanduser() if scripts_dir else repo_root
    if not scripts_path.is_absolute():
        scripts_path = repo_root / scripts_path

    return Settings(
        repo_root=repo_root,
        scripts_dir=scripts_path.resolve(),
        profiles=profiles,
        link_name=_env("ORASYNC_LINK_NAME", "SYNC_LINK_B") or "SYNC_LINK_B",
        link_user=_env("ORASYNC_LINK_USER", "") or "",
        env_file=dotenv_path if dotenv_path.is_file() else None,
    )
