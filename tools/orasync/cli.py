"""Interface en ligne de commande de l'outillage ora_sync."""

from __future__ import annotations

import argparse
import sys

from . import __version__
from .config import ConfigError, from_env
from .logging_utils import setup_logging
from .project import (
    check_profiles,
    fetch_status,
    install_core,
    migrate,
    run_harness,
    run_sample,
    run_sql_file,
)

PROG = "setup_project.py"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Outillage de deploiement et de test du projet ora_sync.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Exemples :\n"
            f"  python {PROG} check\n"
            f"  python {PROG} setup --with-sample\n"
            f"  python {PROG} test\n"
            f"  python {PROG} sql 09_test_sync_mode.sql\n"
        ),
    )
    parser.add_argument("--version", action="version", version=f"ora_sync {__version__}")
    parser.add_argument("--env-file", help="chemin du fichier .env a charger")
    parser.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="verbosite (-v : debug, -vv : debug + journal fichier)",
    )
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--dry-run",
        action="store_true",
        help="affiche les actions sans executer les scripts",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("check", help="verifie les connexions Oracle", parents=[common])

    install = sub.add_parser(
        "install", help="cree les tables et le package", parents=[common]
    )
    install.add_argument(
        "--no-migrate",
        action="store_true",
        help="ne pas appliquer la migration 08 apres la creation",
    )

    sub.add_parser(
        "migrate", help="applique la migration idempotente 08", parents=[common]
    )

    sample = sub.add_parser(
        "sample", help="charge les donnees et la config d'exemple", parents=[common]
    )
    sample.add_argument(
        "--link-user",
        help="utilisateur du database link (sinon ORASYNC_LINK_USER)",
    )

    sub.add_parser("test", help="execute le harnais de tests 07", parents=[common])

    sql = sub.add_parser("sql", help="execute un script SQL*Plus", parents=[common])
    sql.add_argument("file", help="fichier .sql a executer")
    sql.add_argument("--profile", default="admin", help="profil de connexion (defaut : admin)")
    sql.add_argument(
        "--continue-on-error",
        action="store_true",
        help="ignore les erreurs d'idempotence DDL et poursuit l'execution",
    )

    status = sub.add_parser(
        "status", help="affiche les dernieres synchronisations", parents=[common]
    )
    status.add_argument("--limit", type=int, default=10, help="nombre de lignes (defaut : 10)")

    setup = sub.add_parser(
        "setup",
        help="installation complete (install [+ sample] [+ tests])",
        parents=[common],
    )
    setup.add_argument("--with-sample", action="store_true", help="charge les donnees d'exemple")
    setup.add_argument("--run-tests", action="store_true", help="execute le harnais 07")
    setup.add_argument("--no-migrate", action="store_true", help="ne pas appliquer la migration 08")

    return parser


def _cmd_check(args, settings) -> int:
    results = check_profiles(settings)
    width = max((len(name) for name, _, _ in results), default=4)
    for name, ok, detail in results:
        marker = "OK " if ok else "KO "
        print(f"  [{marker}] {name.ljust(width)}  {detail}")
    required = [item for item in results if item[0] != "sys"]
    if all(ok for _, ok, _ in required):
        print("Connexions requises operationnelles.")
        return 0
    print("Connexions requises incompletes.", file=sys.stderr)
    return 1


def _cmd_install(args, settings) -> int:
    install_core(settings, with_migration=not args.no_migrate, dry_run=args.dry_run)
    if not args.dry_run:
        print("Installation terminee.")
    return 0


def _cmd_migrate(args, settings) -> int:
    migrate(settings, dry_run=args.dry_run)
    if not args.dry_run:
        print("Migration terminee.")
    return 0


def _cmd_sample(args, settings) -> int:
    run_sample(settings, link_user=args.link_user, dry_run=args.dry_run)
    if not args.dry_run:
        print("Donnees et configuration d'exemple chargees.")
    return 0


def _cmd_test(args, settings) -> int:
    run_harness(settings, dry_run=args.dry_run)
    if not args.dry_run:
        print("Harnais de tests execute.")
    return 0


def _cmd_sql(args, settings) -> int:
    run_sql_file(
        settings,
        args.file,
        args.profile,
        stop_on_error=not args.continue_on_error,
        tolerate_idempotent_errors=args.continue_on_error,
        dry_run=args.dry_run,
    )
    return 0


def _cmd_status(args, settings) -> int:
    rows = fetch_status(settings, limit=args.limit)
    if not rows:
        print("Aucune execution enregistree.")
        return 0
    headers = ["run_id", "run_type", "status", "start_date", "total", "ok", "ko"]
    data = [[str(item) if item is not None else "" for item in row] for row in rows]
    widths = [len(head) for head in headers]
    for row in data:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))
    print(" | ".join(head.ljust(widths[i]) for i, head in enumerate(headers)))
    print("-+-".join("-" * width for width in widths))
    for row in data:
        print(" | ".join(value.ljust(widths[i]) for i, value in enumerate(row)))
    return 0


def _cmd_setup(args, settings) -> int:
    install_core(settings, with_migration=not args.no_migrate, dry_run=args.dry_run)
    if args.with_sample:
        run_sample(settings, dry_run=args.dry_run)
    if args.run_tests:
        run_harness(settings, dry_run=args.dry_run)
    if not args.dry_run:
        print("Setup termine.")
    return 0


_HANDLERS = {
    "check": _cmd_check,
    "install": _cmd_install,
    "migrate": _cmd_migrate,
    "sample": _cmd_sample,
    "test": _cmd_test,
    "sql": _cmd_sql,
    "status": _cmd_status,
    "setup": _cmd_setup,
}


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    setup_logging(args.verbose)

    try:
        settings = from_env(env_file=args.env_file)
    except ConfigError as exc:
        print(f"Erreur de configuration : {exc}", file=sys.stderr)
        return 2

    handler = _HANDLERS[args.command]
    try:
        return handler(args, settings)
    except ConfigError as exc:
        print(f"Erreur : {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:  # pragma: no cover
        print("Interrompu.", file=sys.stderr)
        return 130


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
