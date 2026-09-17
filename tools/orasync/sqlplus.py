"""Mini-interpreteur SQL*Plus en Python pur.

Le runner execute les scripts du projet sans dependre du binaire ``sqlplus``.
Il reproduit le comportement utile du client Oracle :

* les commandes SQL*Plus ne sont reconnues que lorsque le tampon de requete
  est vide (afin de ne pas confondre une commande avec du code PL/SQL) ;
* les blocs PL/SQL (``DECLARE``/``BEGIN``/``CREATE ... PACKAGE`` ...) sont
  termines par une ligne ``/`` ;
* les instructions SQL sont separees par un ``;`` de premier niveau
  (les chaines et commentaires sont ignores lors du decoupage) ;
* ``DBMS_OUTPUT`` est active et vide apres chaque instruction ;
* les erreurs de compilation PL/SQL (``USER_ERRORS``) sont remontees.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import oracledb

LOGGER = logging.getLogger("orasync")

_COMMANDS = {
    "SET",
    "PROMPT",
    "COLUMN",
    "COL",
    "SPOOL",
    "SPOOL",
    "WHENEVER",
    "DEFINE",
    "UNDEFINE",
    "VARIABLE",
    "VAR",
    "PRINT",
    "SHOW",
    "TTITLE",
    "BTITLE",
    "REPHEADER",
    "REPFOOTER",
    "BREAK",
    "COMPUTE",
    "HOST",
    "REM",
    "REMARK",
    "PAUSE",
    "CLEAR",
    "START",
    "ACCEPT",
    "STORE",
    "SAVE",
    "GET",
    "EDIT",
    "DEL",
    "LIST",
    "INPUT",
    "APPEND",
    "RUN",
}

_EXIT_COMMANDS = {"EXIT", "QUIT"}

_PLSQL_PREFIX = re.compile(
    r"^(DECLARE|BEGIN)\b"
    r"|^CREATE\s+(OR\s+REPLACE\s+)?"
    r"(PACKAGE|PROCEDURE|FUNCTION|TRIGGER|TYPE|LIBRARY|JAVA)\b",
    re.IGNORECASE | re.DOTALL,
)

_UNIT_PATTERN = re.compile(
    r"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?"
    r"(PACKAGE\s+BODY|PACKAGE|PROCEDURE|FUNCTION|TRIGGER|TYPE\s+BODY|TYPE)\s+"
    r'("?[A-Za-z0-9_$#]+"?)',
    re.IGNORECASE,
)

_CMD_PATTERN = re.compile(r"^([A-Za-z]+)\b\s*(.*)$", re.DOTALL)


class SqlScriptError(RuntimeError):
    """Erreur bloquante lors de l'execution d'un script SQL."""


# Erreurs Oracle attendues lors du rejeu de scripts DDL idempotents.
# Elles sont tolerees (journalisees en avertissement) uniquement lorsque
# `tolerate_idempotent_errors` est actif.
_IDEMPOTENT_ERROR_CODES = {
    955,    # ORA-00955 : name is already used by an existing object
    942,    # ORA-00942 : table or view does not exist
    4043,   # ORA-04043 : object does not exist
    14452,  # ORA-14452 : temporary table already in use (DROP de GTT)
    1430,   # ORA-01430 : column being added already exists
    1442,   # ORA-01442 : column already NOT NULL
    1451,   # ORA-01451 : column to be modified to NULL cannot be modified
    2260,   # ORA-02260 : table can have only one primary key
    2264,   # ORA-02264 : name already used by an existing constraint
    2275,   # ORA-02275 : such a referential constraint already exists
    2289,   # ORA-02289 : sequence does not exist
    2443,   # ORA-02443 : cannot drop constraint - nonexistent constraint
    1408,   # ORA-01408 : such column list already indexed
}


@dataclass
class RunStats:
    statements: int = 0
    selects: int = 0
    rows: int = 0
    prompts: int = 0
    errors: int = 0
    tolerated: int = 0

    def merge(self, other: "RunStats") -> None:
        self.statements += other.statements
        self.selects += other.selects
        self.rows += other.rows
        self.prompts += other.prompts
        self.errors += other.errors
        self.tolerated += other.tolerated


class SqlPlusRunner:
    """Execute un (ou plusieurs) script(s) SQL*Plus sur une connexion."""

    def __init__(
        self,
        connection: oracledb.Connection,
        *,
        source: str = "<sql>",
        stop_on_error: bool = True,
        tolerate_idempotent_errors: bool = False,
        echo: bool = False,
        show_selects: bool = True,
        max_rows: int = 200,
        emit: Callable[[str], None] | None = None,
    ) -> None:
        self.connection = connection
        self.source = source
        self.stop_on_error = stop_on_error
        self.tolerate_idempotent_errors = tolerate_idempotent_errors
        self.echo = echo
        self.show_selects = show_selects
        self.max_rows = max_rows
        self.stats = RunStats()
        self._emit = emit or (lambda line: print(line))
        self._output_enabled = False

    # -- API publique ---------------------------------------------------------

    def run_file(self, path: Path) -> RunStats:
        path = Path(path)
        if not path.is_file():
            raise SqlScriptError(f"Script introuvable : {path}")
        LOGGER.info("execution du script %s", path)
        text = path.read_text(encoding="utf-8", errors="replace")
        previous = self.source
        self.source = str(path)
        try:
            self.run_text(text, base_dir=path.parent)
        finally:
            self.source = previous
        return self.stats

    def run_text(self, text: str, base_dir: Path | None = None) -> RunStats:
        self._enable_output()
        buffer = ""
        mode: str | None = None

        for raw in text.splitlines():
            stripped = raw.strip()
            in_buffer = bool(buffer.strip())

            if not in_buffer:
                if stripped == "/":
                    continue
                if self._is_comment_line(stripped) or stripped == "":
                    continue
                command = self._parse_command(stripped)
                if command is not None:
                    name, argument = command
                    if name in _EXIT_COMMANDS:
                        return self.stats
                    if self._handle_command(name, argument, base_dir):
                        return self.stats
                    continue

            buffer += raw + "\n"
            if mode is None:
                mode = self._detect_mode(buffer)

            if mode == "plsql":
                if stripped == "/":
                    block = buffer[: buffer.rfind("/")]
                    buffer = ""
                    mode = None
                    self._execute(block)
            else:
                buffer = self._drain_sql(buffer)
                if not buffer.strip():
                    mode = None

        if buffer.strip():
            if mode == "sql":
                self._drain_sql(buffer)
            else:
                LOGGER.warning(
                    "bloc PL/SQL non termine dans %s (ligne '/' manquante)",
                    self.source,
                )
        return self.stats

    # -- Detection / decoupage ------------------------------------------------

    @staticmethod
    def _is_comment_line(line: str) -> bool:
        if line.startswith("--"):
            return True
        return bool(re.match(r"(?i)^REM(\s|$)", line))

    @staticmethod
    def _detect_mode(text: str) -> str:
        return "plsql" if _PLSQL_PREFIX.match(text.lstrip()) else "sql"

    def _parse_command(self, line: str) -> tuple[str, str] | None:
        if line.startswith("@"):
            return ("@@", line[2:]) if line.startswith("@@") else ("@", line[1:])
        match = _CMD_PATTERN.match(line)
        if not match:
            return None
        name = match.group(1).upper()
        if name in _COMMANDS or name in ("EXEC", "EXECUTE"):
            return name, match.group(2)
        return None

    def _handle_command(self, name: str, argument: str, base_dir: Path | None) -> bool:
        argument = argument.strip()
        if name == "PROMPT":
            text = argument[1:] if argument.startswith(" ") else argument
            self._emit(text)
            self.stats.prompts += 1
        elif name in ("EXEC", "EXECUTE"):
            self._exec_command(argument)
        elif name in ("@", "@@"):
            self._include(argument, base_dir)
        elif name == "SET":
            LOGGER.debug("commande SQL*Plus ignoree : SET %s", argument)
        else:
            LOGGER.debug("commande SQL*Plus ignoree : %s %s", name, argument)
        return False

    def _exec_command(self, argument: str) -> None:
        body = argument.strip()
        if not body:
            return
        body = body.rstrip()
        if body.endswith(";"):
            body = body[:-1]
        self._execute(f"BEGIN {body}; END;")

    def _include(self, argument: str, base_dir: Path | None) -> None:
        target = argument.strip().strip('"').strip("'")
        if not target:
            return
        path = Path(target)
        if not path.is_absolute():
            base = base_dir or Path.cwd()
            path = (base / target).resolve()
        self.run_file(path)

    @staticmethod
    def _find_statement_end(text: str) -> int:
        """Index du premier ';' de premier niveau, -1 si absent."""

        index = 0
        length = len(text)
        in_single = in_double = False
        while index < length:
            char = text[index]
            if in_single:
                if char == "'":
                    if index + 1 < length and text[index + 1] == "'":
                        index += 2
                        continue
                    in_single = False
            elif in_double:
                if char == '"':
                    if index + 1 < length and text[index + 1] == '"':
                        index += 2
                        continue
                    in_double = False
            elif char == "'":
                in_single = True
            elif char == '"':
                in_double = True
            elif char == "-" and index + 1 < length and text[index + 1] == "-":
                newline = text.find("\n", index)
                if newline == -1:
                    return -1
                index = newline
                continue
            elif char == "/" and index + 1 < length and text[index + 1] == "*":
                end = text.find("*/", index + 2)
                if end == -1:
                    return -1
                index = end + 2
                continue
            elif char == ";":
                return index
            index += 1
        return -1

    def _drain_sql(self, buffer: str) -> str:
        while True:
            end = self._find_statement_end(buffer)
            if end == -1:
                return buffer
            statement = buffer[:end]
            buffer = buffer[end + 1 :]
            if statement.strip():
                self._execute(statement)

    # -- Execution ------------------------------------------------------------

    def _enable_output(self) -> None:
        if self._output_enabled:
            return
        with self.connection.cursor() as cursor:
            cursor.execute("BEGIN DBMS_OUTPUT.ENABLE(NULL); END;")
        self._output_enabled = True

    def _execute(self, statement: str) -> None:
        statement = statement.strip()
        if not statement:
            return
        if self.echo:
            self._emit(f"- {statement}")
        LOGGER.debug("statement (%s) : %s", self.source, _preview(statement))
        try:
            with self.connection.cursor() as cursor:
                cursor.execute(statement)
                description = cursor.description
                rows = cursor.fetchall() if description else None
        except oracledb.Error as exc:
            code = _error_code(exc)
            self._drain_output()
            if self.tolerate_idempotent_errors and abs(code) in _IDEMPOTENT_ERROR_CODES:
                self.stats.tolerated += 1
                LOGGER.warning(
                    "instruction ignoree (idempotence, ORA-%05d) : %s",
                    abs(code),
                    _preview(statement),
                )
                return
            self.stats.errors += 1
            LOGGER.error("%s : %s", _preview(statement), _format_error(exc))
            if self.stop_on_error:
                raise SqlScriptError(
                    f"Echec de l'instruction dans {self.source} : "
                    f"{_preview(statement)}\n{_format_error(exc)}"
                ) from exc
            return

        self.stats.statements += 1
        self._drain_output()

        if description and rows is not None and self.show_selects:
            self.stats.selects += 1
            self.stats.rows += len(rows)
            self._print_rows(description, rows)

        self._check_compile_errors(statement)

    def _check_compile_errors(self, statement: str) -> None:
        match = _UNIT_PATTERN.match(statement)
        if not match:
            return
        unit_type = re.sub(r"\s+", " ", match.group(1).upper())
        name = match.group(2).strip('"').upper()
        with self.connection.cursor() as cursor:
            cursor.execute(
                "SELECT line, position, text FROM user_errors "
                "WHERE name = :name AND type = :type ORDER BY sequence",
                name=name,
                type=unit_type,
            )
            errors = cursor.fetchall()
        if not errors:
            return
        self.stats.errors += 1
        details = "\n".join(
            f"  ligne {line or 0}, col {position or 0} : {text or ''}"
            for line, position, text in errors
        )
        raise SqlScriptError(
            f"Erreurs de compilation pour {unit_type} {name} :\n{details}"
        )

    def _drain_output(self) -> None:
        try:
            with self.connection.cursor() as cursor:
                line = cursor.var(str)
                status = cursor.var(int)
                while True:
                    cursor.callproc("dbms_output.get_line", (line, status))
                    if status.getvalue() == 1:
                        break
                    value = line.getvalue()
                    if value is not None:
                        self._emit(value)
        except oracledb.Error as exc:  # pragma: no cover
            LOGGER.debug("lecture DBMS_OUTPUT impossible : %s", exc)

    def _print_rows(self, description, rows) -> None:
        columns = [col[0] for col in description]
        display = [[_cell(value) for value in row] for row in rows]
        widths = [len(name) for name in columns]
        for row in display:
            for index, value in enumerate(row):
                widths[index] = max(widths[index], len(value))

        self._emit(" | ".join(name.ljust(widths[i]) for i, name in enumerate(columns)))
        self._emit("-+-".join("-" * width for width in widths))
        for row in display[: self.max_rows]:
            self._emit(" | ".join(value.ljust(widths[i]) for i, value in enumerate(row)))
        if len(display) > self.max_rows:
            self._emit(f"... ({len(display) - self.max_rows} lignes supplementaires)")


def _cell(value) -> str:
    if value is None:
        return ""
    if isinstance(value, oracledb.LOB):
        return "<LOB>"
    return str(value)


def _preview(statement: str, limit: int = 100) -> str:
    text = " ".join(statement.split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


def _format_error(exc: oracledb.Error) -> str:
    error = exc.args[0] if exc.args else exc
    message = getattr(error, "message", str(error))
    return str(message).strip()


def _error_code(exc: oracledb.Error) -> int:
    error = exc.args[0] if exc.args else exc
    code = getattr(error, "code", None)
    if code is None:
        return 0
    try:
        return int(code)
    except (TypeError, ValueError):  # pragma: no cover
        return 0
