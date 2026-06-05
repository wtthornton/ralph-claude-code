"""Language-specific import-graph builders.

Split out of ralph_sdk.import_graph: the Python (ast) and JS/TS (regex)
file-dependency extractors and their per-language build_*_graph entry points.
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

_SKIP_DIRS = {"node_modules", ".venv", "__pycache__", ".git", ".ralph", ".cache"}


_PY_MODULE_EXTS = (".py", "/__init__.py")


def _resolve_python_module(module: str, root: Path) -> str | None:
    """Map a dotted module path to its on-disk source relative to `root`."""
    mod_path = module.replace(".", "/")
    for ext in _PY_MODULE_EXTS:
        candidate = root / (mod_path + ext)
        if candidate.exists():
            return str(candidate.relative_to(root))
    return None


def _python_imports_for_node(node: ast.AST, root: Path) -> list[str]:
    if isinstance(node, ast.ImportFrom) and node.module:
        rel = _resolve_python_module(node.module, root)
        return [rel] if rel else []
    if isinstance(node, ast.Import):
        return [
            rel for alias in node.names
            if (rel := _resolve_python_module(alias.name, root)) is not None
        ]
    return []


def _python_file_deps(file_path: Path, root: Path) -> list[str]:
    tree = ast.parse(file_path.read_text(encoding="utf-8", errors="ignore"))
    deps: list[str] = []
    for node in ast.walk(tree):
        deps.extend(_python_imports_for_node(node, root))
    return sorted({d.replace("\\", "/") for d in deps})


def build_python_graph(project_root: Path) -> dict[str, list[str]]:
    """Build import graph for Python project via ast.parse().

    Returns a dict mapping relative file path to its sorted dependency paths.
    """
    root = project_root.resolve()
    graph: dict[str, list[str]] = {}
    for f in root.rglob("*.py"):
        if any(part in _SKIP_DIRS for part in f.parts):
            continue
        try:
            deps = _python_file_deps(f, root)
        except (SyntaxError, UnicodeDecodeError, OSError):
            continue
        rel = str(f.relative_to(root)).replace("\\", "/")
        graph[rel] = deps
    return graph


_JS_IMPORT_RE = re.compile(
    r"""(?:import\s+.*?from\s+['"](.+?)['"]|require\(['"](.+?)['"]\))"""
)
_JS_RESOLVE_EXTS = ["", ".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.js"]


def _resolve_js_dep(candidate: Path, root: Path) -> str | None:
    """Resolve a JS/TS relative import to a repo-relative path, or None."""
    for try_ext in _JS_RESOLVE_EXTS:
        full = Path(str(candidate) + try_ext)
        if full.exists():
            try:
                return str(full.relative_to(root)).replace("\\", "/")
            except ValueError:
                return None
    return None


def _js_file_deps(f: Path, root: Path) -> list[str]:
    """Extract resolved relative dependency paths from a single JS/TS file."""
    content = f.read_text(encoding="utf-8", errors="ignore")
    resolved: set[str] = set()
    for m in _JS_IMPORT_RE.finditer(content):
        dep = m.group(1) or m.group(2)
        if not dep.startswith("."):
            continue  # skip bare package imports
        rel = _resolve_js_dep((f.parent / dep).resolve(), root)
        if rel is not None:
            resolved.add(rel)
    return sorted(resolved)


def build_js_graph(project_root: Path) -> dict[str, list[str]]:
    """Build import graph for JS/TS project via regex extraction.

    Returns:
        Dict mapping relative file path to list of relative dependency paths.
    """
    root = project_root.resolve()
    graph: dict[str, list[str]] = {}
    js_extensions = ["*.js", "*.jsx", "*.ts", "*.tsx"]

    for ext_pattern in js_extensions:
        for f in root.rglob(ext_pattern):
            if any(part in _SKIP_DIRS for part in f.parts):
                continue
            try:
                deps = _js_file_deps(f, root)
            except (UnicodeDecodeError, OSError):
                continue
            graph[str(f.relative_to(root)).replace("\\", "/")] = deps

    return graph
