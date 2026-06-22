"""File dependency graph via AST parsing.

Port of lib/import_graph.sh to Python. Builds a file-level import graph
and caches it for use by the plan optimizer.

Language support:
  - Python: ast.parse() (zero external deps)
  - JS/TS: regex-based extraction (import/require)
  - Other: empty graph, falls back to directory proximity
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from ralph_sdk.graph_builders import build_js_graph, build_python_graph

__all__ = [
    "CachedImportGraph",
    "build_import_graph",
    "build_js_graph",
    "build_python_graph",
]


def build_import_graph(
    project_root: str | Path,
    project_type: str | None = None,
) -> dict[str, list[str]]:
    """Auto-detect project type and build import graph.

    Args:
        project_root: Path to the project root.
        project_type: Override auto-detection ("python", "javascript", etc.).

    Returns:
        Dict mapping file path to list of dependency file paths.
    """
    root = Path(project_root).resolve()

    if project_type is None:
        if (root / "pyproject.toml").exists() or (root / "setup.py").exists():
            project_type = "python"
        elif (root / "package.json").exists() or (root / "tsconfig.json").exists():
            project_type = "javascript"

    if project_type == "python":
        return build_python_graph(root)
    elif project_type in ("javascript", "typescript", "js", "ts"):
        return build_js_graph(root)
    return {}


class CachedImportGraph:
    """Import graph with JSON file caching and staleness detection.

    Args:
        project_root: Path to the project root.
        cache_path: Path to the cache file (default: .ralph/.import_graph.json).
        max_age_seconds: Cache staleness threshold (default: 3600 = 1 hour).
        project_type: Override auto-detection.
    """

    def __init__(
        self,
        project_root: str | Path,
        cache_path: str | Path | None = None,
        max_age_seconds: int = 3600,
        project_type: str | None = None,
    ) -> None:
        self.project_root = Path(project_root).resolve()
        self.cache_path = Path(
            cache_path or (self.project_root / ".ralph" / ".import_graph.json")
        )
        self.max_age_seconds = max_age_seconds
        self.project_type = project_type
        self._graph: dict[str, list[str]] | None = None

    def get(self) -> dict[str, list[str]]:
        """Get the import graph, rebuilding if stale or missing."""
        if self._graph is not None:
            return self._graph

        if self._is_cache_fresh():
            try:
                data = json.loads(self.cache_path.read_text())
                if isinstance(data, dict):
                    self._graph = data
                    return self._graph
            except (json.JSONDecodeError, OSError):
                pass

        self._graph = self.rebuild()
        return self._graph

    def rebuild(self) -> dict[str, list[str]]:
        """Force rebuild the import graph and update cache."""
        graph = build_import_graph(self.project_root, self.project_type)
        self._graph = graph
        try:
            self.cache_path.parent.mkdir(parents=True, exist_ok=True)
            self.cache_path.write_text(json.dumps(graph, indent=2))
        except OSError:
            pass
        return graph

    def invalidate(self) -> None:
        """Mark the cache as stale."""
        self._graph = None
        try:
            self.cache_path.unlink(missing_ok=True)
        except OSError:
            pass

    def imports(self, file_a: str, file_b: str) -> bool:
        """Check if file_a imports file_b."""
        graph = self.get()
        return file_b in graph.get(file_a, [])

    def _is_cache_fresh(self) -> bool:
        if not self.cache_path.exists():
            return False
        try:
            age = time.time() - self.cache_path.stat().st_mtime
            return age < self.max_age_seconds
        except OSError:
            return False
