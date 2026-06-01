"""Filesystem project-detection helpers for semantic memory.

Split out of memory.py: pure functions that inspect a project root to detect
language, test runner, file count, top-level directories, and config files.
Consumed by ``MemoryManager.generate_project_index``.
"""

from __future__ import annotations

import logging
from pathlib import Path

logger = logging.getLogger("ralph.sdk.memory")


def _detect_language(root: Path) -> str:
    if (root / "package.json").exists() or list(root.glob("*.ts"))[:1]:
        return "javascript/typescript"
    markers: tuple[tuple[tuple[str, ...], str], ...] = (
        (("pyproject.toml", "setup.py"), "python"),
        (("go.mod",), "go"),
        (("Cargo.toml",), "rust"),
        (("pom.xml", "build.gradle"), "java"),
    )
    for files, language in markers:
        if any((root / f).exists() for f in files):
            return language
    if list(root.glob("*.sh"))[:1]:
        return "bash"
    return "unknown"


def _detect_js_test_runner(root: Path) -> str | None:
    """Detect jest/vitest from package.json, or None."""
    pkg = root / "package.json"
    if not pkg.exists():
        return None
    try:
        text = pkg.read_text()
    except OSError as e:
        logger.debug("package.json read failed: %s", e)
        return None
    if '"jest"' in text:
        return "jest"
    if '"vitest"' in text:
        return "vitest"
    return None


def _detect_py_test_runner(root: Path) -> str | None:
    """Detect pytest from pyproject.toml, or None."""
    pyproj = root / "pyproject.toml"
    if not pyproj.exists():
        return None
    try:
        if "pytest" in pyproj.read_text():
            return "pytest"
    except OSError as e:
        logger.debug("pyproject.toml read failed: %s", e)
    return None


def _detect_test_runner(root: Path) -> str:
    runner = _detect_js_test_runner(root) or _detect_py_test_runner(root)
    if runner:
        return runner
    if list(root.glob("tests/*.bats"))[:1]:
        return "bats"
    if (root / "go.mod").exists():
        return "go test"
    return "unknown"


def _count_files(root: Path) -> int:
    skip = {".git", "node_modules", ".ralph", "__pycache__", ".cache", ".venv"}
    count = 0
    try:
        for item in root.rglob("*"):
            if item.is_file() and not any(p in item.parts for p in skip):
                count += 1
                if count > 10000:
                    break
    except (PermissionError, OSError):
        pass
    return count


def _detect_top_dirs(root: Path) -> str:
    skip = {"node_modules", ".git", ".ralph", "__pycache__", ".cache", ".venv"}
    dirs = []
    try:
        for item in sorted(root.iterdir()):
            if item.is_dir() and item.name not in skip and not item.name.startswith("."):
                dirs.append(item.name)
                if len(dirs) >= 10:
                    break
    except (PermissionError, OSError):
        pass
    return ",".join(dirs)


def _detect_configs(root: Path) -> str:
    candidates = [
        ".ralphrc", "ralph.config.json", "package.json", "pyproject.toml",
        "tsconfig.json", "Cargo.toml", "go.mod", "pom.xml",
    ]
    found = [c for c in candidates if (root / c).exists()]
    return ",".join(found)
