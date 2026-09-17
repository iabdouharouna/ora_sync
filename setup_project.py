#!/usr/bin/env python3
"""Bootstrap et point d'entree du projet ora_sync.

Ce script n'utilise que la bibliotheque standard Python. Il :

1. cree un environnement virtuel local (``.venv``) si necessaire ;
2. installe les dependances de ``requirements.txt`` (empreinte SHA-256 pour
   ne reinstaller qu'en cas de changement) ;
3. se re-execute dans cet environnement ;
4. delegue a la CLI ``orasync`` (package ``tools/orasync``).

Exemples :

    python setup_project.py check
    python setup_project.py setup --with-sample
    python setup_project.py test
    python setup_project.py sql 09_test_sync_mode.sql
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import venv
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEFAULT_VENV = ROOT / ".venv"
REQUIREMENTS = ROOT / "requirements.txt"
STAMP_NAME = ".orasync-deps.sha256"


def _venv_dir() -> Path:
    override = os.environ.get("ORASYNC_VENV")
    if override:
        path = Path(override).expanduser()
        return path if path.is_absolute() else (ROOT / path)
    return DEFAULT_VENV


def _venv_python(venv_dir: Path) -> Path:
    if os.name == "nt":
        return venv_dir / "Scripts" / "python.exe"
    return venv_dir / "bin" / "python"


def _in_venv(venv_dir: Path) -> bool:
    try:
        return Path(sys.prefix).resolve() == venv_dir.resolve()
    except OSError:
        return False


def _deps_digest() -> str:
    digest = hashlib.sha256()
    digest.update(f"python={sys.version_info.major}.{sys.version_info.minor}\n".encode())
    if REQUIREMENTS.is_file():
        digest.update(REQUIREMENTS.read_bytes())
    return digest.hexdigest()


def _log(message: str) -> None:
    print(f"[bootstrap] {message}", file=sys.stderr)


def _create_venv(venv_dir: Path) -> Path:
    """Cree l'environnement virtuel en tolerant l'absence d'ensurepip."""

    python = _venv_python(venv_dir)
    if python.exists():
        return python

    _log(f"creation de l'environnement virtuel : {venv_dir}")
    try:
        venv.EnvBuilder(with_pip=True).create(str(venv_dir))
    except BaseException as exc:  # noqa: BLE001 - ensurepip leve SystemExit
        _log(
            f"ensurepip indisponible ({type(exc).__name__}) : "
            "creation de l'environnement sans pip, puis bootstrap via le pip hote."
        )
        venv.EnvBuilder(with_pip=False, clear=True).create(str(venv_dir))

    python = _venv_python(venv_dir)
    if not python.exists():
        raise SystemExit(
            f"[bootstrap] interpreteur introuvable dans {venv_dir}. "
            "Supprimez le dossier puis relancez."
        )
    return python


def _has_pip(python: Path) -> bool:
    try:
        subprocess.check_call(
            [str(python), "-m", "pip", "--version"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except (OSError, subprocess.CalledProcessError):
        return False


def _ensure_pip(python: Path) -> None:
    if _has_pip(python):
        return
    _log("bootstrap de pip dans l'environnement virtuel ...")
    subprocess.check_call(
        [sys.executable, "-m", "pip", "--python", str(python), "install", "--upgrade", "pip"]
    )


def _ensure_venv() -> None:
    if os.environ.get("ORASYNC_NO_VENV") == "1":
        return

    venv_dir = _venv_dir()
    if _in_venv(venv_dir):
        return

    python = _create_venv(venv_dir)
    _ensure_pip(python)

    stamp = venv_dir / STAMP_NAME
    digest = _deps_digest()
    if not stamp.is_file() or stamp.read_text(encoding="utf-8").strip() != digest:
        _log("installation des dependances (requirements.txt) ...")
        subprocess.check_call([str(python), "-m", "pip", "install", "--upgrade", "pip"])
        subprocess.check_call(
            [str(python), "-m", "pip", "install", "-r", str(REQUIREMENTS)]
        )
        stamp.write_text(digest, encoding="utf-8")

    os.execv(str(python), [str(python), str(ROOT / "setup_project.py"), *sys.argv[1:]])


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    _ensure_venv()

    sys.path.insert(0, str(ROOT / "tools"))
    try:
        from orasync.cli import main as cli_main
    except ImportError as exc:  # pragma: no cover
        print(f"[bootstrap] import de orasync impossible : {exc}", file=sys.stderr)
        print(
            "[bootstrap] verifiez l'installation des dependances "
            "(ou definissez ORASYNC_NO_VENV=1 pour utiliser l'interpreteur courant).",
            file=sys.stderr,
        )
        return 2

    return cli_main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
