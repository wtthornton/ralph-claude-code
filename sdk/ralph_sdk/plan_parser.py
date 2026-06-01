"""fix_plan.md parsing + task classification for the plan optimizer.

Splits the line-level parsing concern out of the reordering engine: the
:class:`Task` model, the regex table, :func:`parse_tasks`, file extraction,
size estimation, and :func:`phase_rank`. The reordering engine in
``plan_optimizer`` imports these back so the public API is unchanged.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

_FILE_PATTERN = re.compile(
    r"[a-zA-Z0-9_/./-]+\.(?:py|ts|tsx|js|jsx|sh|json|yaml|yml|toml|md|css|html|go|rs|rb|java)"
)
_BACKTICK_FILE = re.compile(r"`([^`]+\.[a-zA-Z]+)`")
_METADATA_ID = re.compile(r"<!--\s*id:\s*([a-zA-Z0-9_-]+)\s*-->")
_METADATA_DEPENDS = re.compile(r"<!--\s*depends:\s*([a-zA-Z0-9_-]+)\s*-->")
_METADATA_RESOLVED = re.compile(r"<!--\s*resolved:\s*([a-zA-Z0-9_/./-]+)\s*-->")
_CHECKBOX = re.compile(r"^- \[([xX ])\]\s*(.*)")
_SECTION = re.compile(r"^## (.+)")


@dataclass
class Task:
    """A parsed task from fix_plan.md."""

    idx: int = 0
    line_num: int = 0
    section: str = ""
    text: str = ""
    raw_line: str = ""
    checked: bool = False
    files: list[str] = field(default_factory=list)
    task_id: str = ""
    depends: str = ""
    size: int = 1  # 0=SMALL, 1=MEDIUM, 2=LARGE


def parse_tasks(fix_plan_path: str | Path) -> list[Task]:
    """Parse fix_plan.md into structured Task objects."""
    path = Path(fix_plan_path)
    if not path.exists():
        return []

    tasks: list[Task] = []
    current_section = ""

    for line_num, line in enumerate(path.read_text().splitlines(), 1):
        sec_match = _SECTION.match(line)
        if sec_match:
            current_section = sec_match.group(0)
            continue

        cb_match = _CHECKBOX.match(line)
        if not cb_match:
            continue

        tasks.append(_parse_task_line(cb_match, line, line_num, current_section, len(tasks)))

    return tasks


def _extract_files(text: str) -> list[str]:
    """Extract file paths from backtick refs, bare paths, and resolved metadata."""
    files: list[str] = [m.group(1) for m in _BACKTICK_FILE.finditer(text)]

    for m in _FILE_PATTERN.finditer(text):
        if m.group() not in files:
            files.append(m.group())

    resolved = _METADATA_RESOLVED.search(text)
    if resolved and resolved.group(1) not in files:
        files.append(resolved.group(1))

    return files


def _parse_task_line(
    cb_match: re.Match[str],
    line: str,
    line_num: int,
    current_section: str,
    idx: int,
) -> Task:
    """Build a Task from a matched checkbox line."""
    checked = cb_match.group(1).lower() == "x"
    text = cb_match.group(2).strip()

    files = _extract_files(text)

    task_id_m = _METADATA_ID.search(text)
    depends_m = _METADATA_DEPENDS.search(text)

    # Clean text for comparison (strip metadata comments)
    clean_text = re.sub(r"<!--\s*[a-zA-Z]+:\s*[a-zA-Z0-9_./ -]+\s*-->", "", text).strip()
    clean_text = re.sub(r"\s+", " ", clean_text)

    return Task(
        idx=idx,
        line_num=line_num,
        section=current_section,
        text=clean_text,
        raw_line=line,
        checked=checked,
        files=files,
        task_id=task_id_m.group(1) if task_id_m else "",
        depends=depends_m.group(1) if depends_m else "",
        size=_estimate_size(clean_text, len(files)),
    )


def _estimate_size(text: str, file_count: int) -> int:
    """Inline size estimation: 0=SMALL, 1=MEDIUM, 2=LARGE."""
    lower = text.lower()
    if file_count <= 1 and re.search(
        r"rename|typo|config|comment|remove unused|fix.*import|bump.*version|update.*version",
        lower,
    ):
        return 0
    if file_count >= 3 or re.search(
        r"redesign|architect|cross.?module|new feature|security|integrate|migrate",
        lower,
    ):
        return 2
    return 1


def phase_rank(text: str) -> int:
    """Keyword-based phase rank.

    0 = create/setup/init/define/schema/scaffold
    1 = implement/add/build/write/develop
    2 = modify/refactor/update/fix/change (default)
    3 = test/spec/verify/validate
    4 = document/readme/comment/changelog/release
    """
    lower = text.lower()
    if re.search(r"create|setup|init|define|schema|scaffold|bootstrap", lower):
        return 0
    if re.search(r"implement|add|build|write|develop", lower):
        return 1
    if re.search(r"test|spec|verify|validate|assert", lower):
        return 3
    if re.search(r"doc|readme|comment|changelog|release", lower):
        return 4
    return 2  # modify/refactor/update/fix default
