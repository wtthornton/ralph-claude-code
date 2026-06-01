"""Fix plan task reordering engine.

Port of lib/plan_optimizer.sh to Python. Reorders unchecked tasks within
each section of fix_plan.md for optimal execution order.

Three-layer dependency detection:
  1. Import graph (highest confidence) — file A imports file B
  2. Explicit metadata (human override) — <!-- id: -->, <!-- depends: -->
  3. Phase convention (lowest priority) — create → implement → test → document

Topological sort for dependency ordering, then secondary sort by
module locality, phase, and size for stable grouping.

Semantic equivalence validation before write (Bazel-inspired).
"""

from __future__ import annotations

import shutil
from dataclasses import dataclass, field
from pathlib import Path

from ralph_sdk.import_graph import CachedImportGraph
from ralph_sdk.plan_parser import (
    _CHECKBOX,
    _SECTION,
    Task,
    _estimate_size,
    parse_tasks,
    phase_rank,
)

__all__ = [
    "Task",
    "parse_tasks",
    "phase_rank",
    "_estimate_size",
    "optimize_plan",
    "OptimizeResult",
]


# =============================================================================
# Dependency detection + topological sort
# =============================================================================


def _metadata_edge(ti: Task, tj: Task) -> tuple[int, int] | None:
    """Layer 2: explicit metadata dependency edge, or None."""
    if tj.depends and tj.depends == ti.task_id:
        return (ti.idx, tj.idx)
    if ti.depends and ti.depends == tj.task_id:
        return (tj.idx, ti.idx)
    return None


def _import_edge(
    ti: Task, tj: Task, import_graph: dict[str, list[str]]
) -> tuple[int, int] | None:
    """Layer 1: import-graph dependency edge between two tasks, or None."""
    for fi in ti.files:
        for fj in tj.files:
            # file_i imports file_j → task j before task i
            if fj in import_graph.get(fi, []):
                return (tj.idx, ti.idx)
            # file_j imports file_i → task i before task j
            if fi in import_graph.get(fj, []):
                return (ti.idx, tj.idx)
    return None


def _build_dependency_edges(
    tasks: list[Task],
    graph: CachedImportGraph | None,
) -> list[tuple[int, int]]:
    """Three-layer dependency detection. Returns (before, after) index pairs."""
    edges: list[tuple[int, int]] = []
    unchecked = [t for t in tasks if not t.checked]
    import_graph = graph.get() if graph is not None else None

    for i, ti in enumerate(unchecked):
        for tj in unchecked[i + 1:]:
            # Never cross sections
            if ti.section != tj.section:
                continue

            # Layer 2: Explicit metadata (human override — highest priority)
            meta = _metadata_edge(ti, tj)
            if meta is not None:
                edges.append(meta)
                continue

            # Layer 1: Import graph
            if import_graph is not None:
                imp = _import_edge(ti, tj, import_graph)
                if imp is not None:
                    edges.append(imp)

    return edges


def _build_adjacency(
    task_count: int, edges: list[tuple[int, int]]
) -> tuple[dict[int, list[int]], dict[int, int]]:
    """Build adjacency list and in-degree map from edges."""
    adj: dict[int, list[int]] = {i: [] for i in range(task_count)}
    in_degree: dict[int, int] = {i: 0 for i in range(task_count)}

    for u, v in edges:
        if u in adj and v in in_degree:
            adj[u].append(v)
            in_degree[v] += 1

    return adj, in_degree


def _topological_sort(task_count: int, edges: list[tuple[int, int]]) -> list[int]:
    """Kahn's algorithm for topological sort. Cycle-tolerant (best-effort)."""
    if not edges:
        return list(range(task_count))

    adj, in_degree = _build_adjacency(task_count, edges)

    queue = [n for n in range(task_count) if in_degree[n] == 0]
    order: list[int] = []

    while queue:
        queue.sort()  # deterministic
        node = queue.pop(0)
        order.append(node)
        for neighbor in adj.get(node, []):
            in_degree[neighbor] -= 1
            if in_degree[neighbor] == 0:
                queue.append(neighbor)

    # Handle cycles: add remaining nodes in original order
    if len(order) < task_count:
        seen = set(order)
        order.extend(i for i in range(task_count) if i not in seen)

    return order


# =============================================================================
# Secondary sort
# =============================================================================


def _module_key(files: list[str]) -> str:
    """Extract primary module from file paths (first 2 path components)."""
    if not files:
        return "zzz_unknown"
    parts = files[0].replace("\\", "/").split("/")
    return "/".join(parts[:2]) if len(parts) >= 2 else parts[0]


def _sort_key(task: Task, topo_rank: int) -> tuple[int, str, int, int, int]:
    """Composite sort key: topo_rank, module, phase, size, original index."""
    return (
        topo_rank,
        _module_key(task.files),
        phase_rank(task.text),
        task.size,
        task.idx,
    )


# =============================================================================
# Validation
# =============================================================================


def _validate_equivalence(before_raw: frozenset[str], after: list[Task]) -> bool:
    """Verify task set is unchanged after reordering (Bazel-inspired).

    TAP-628: the previous implementation compared `sorted(t.text for t in
    before)` against `sorted(t.text for t in after)` where `after` was a
    permutation of the *same* Task objects — so the two sides were always
    identical and the guard could never trip. Snapshot raw_line from the
    pre-transform input as a frozenset so any dedup / filter / rename in the
    sort pipeline is caught.
    """
    if len(before_raw) != len(after):
        return False
    return before_raw == frozenset(t.raw_line for t in after)


# =============================================================================
# Public API
# =============================================================================


def optimize_plan(
    fix_plan_path: str | Path,
    project_root: str | Path | None = None,
    import_graph: CachedImportGraph | None = None,
    *,
    dry_run: bool = False,
) -> OptimizeResult:
    """Reorder unchecked tasks in fix_plan.md for optimal execution.

    Args:
        fix_plan_path: Path to fix_plan.md.
        project_root: Project root for import graph building (auto-detected if None).
        import_graph: Pre-built import graph (built automatically if None).
        dry_run: If True, return result without writing changes.

    Returns:
        OptimizeResult with before/after task lists and change summary.
    """
    fix_plan = Path(fix_plan_path)
    if not fix_plan.exists():
        return OptimizeResult(changed=False, reason="fix_plan.md not found")

    # Parse tasks
    tasks = parse_tasks(fix_plan)
    unchecked = [t for t in tasks if not t.checked]

    if len(unchecked) <= 1:
        return OptimizeResult(changed=False, reason="0-1 unchecked tasks, nothing to optimize")

    # Build import graph if not provided
    if import_graph is None and project_root is not None:
        import_graph = CachedImportGraph(project_root)

    reordered, edges = _reorder_unchecked(tasks, unchecked, import_graph)

    result = _evaluate_reorder(unchecked, reordered, edges)
    if not result.changed or dry_run:
        return result

    # Write optimized plan
    _write_optimized(fix_plan, tasks, reordered)
    return result


def _evaluate_reorder(
    unchecked: list[Task],
    reordered: list[Task],
    edges: list[tuple[int, int]],
) -> OptimizeResult:
    """Validate the reorder and build the OptimizeResult (no I/O)."""
    # Validate semantic equivalence
    unchecked_raw = frozenset(t.raw_line for t in unchecked)
    if not _validate_equivalence(unchecked_raw, reordered):
        return OptimizeResult(changed=False, reason="ABORT: task content changed during reorder")

    # Check if order actually changed
    if [t.idx for t in unchecked] == [t.idx for t in reordered]:
        return OptimizeResult(changed=False, reason="order unchanged after optimization")

    return OptimizeResult(
        changed=True,
        reason=f"reordered {len(unchecked)} tasks ({len(edges)} dependency edges)",
        before=[t.text for t in unchecked],
        after=[t.text for t in reordered],
        dependency_count=len(edges),
    )


def _reorder_unchecked(
    tasks: list[Task],
    unchecked: list[Task],
    import_graph: CachedImportGraph | None,
) -> tuple[list[Task], list[tuple[int, int]]]:
    """Build dependency edges, topo-sort, and apply secondary sort.

    Returns the reordered unchecked tasks and the dependency edges found.
    """
    edges = _build_dependency_edges(tasks, import_graph)
    topo_order = _topological_sort(len(unchecked), edges)

    # Map topo_order back to task indices and apply secondary sort
    topo_rank_map = {
        unchecked[pos].idx: rank
        for rank, pos in enumerate(topo_order)
        if pos < len(unchecked)
    }

    reordered = sorted(
        unchecked,
        key=lambda t: _sort_key(t, topo_rank_map.get(t.idx, t.idx)),
    )
    return reordered, edges


def _write_optimized(fix_plan: Path, all_tasks: list[Task], reordered_unchecked: list[Task]) -> None:
    """Atomic write: backup + rebuild fix_plan.md with reordered tasks."""
    backup = fix_plan.with_suffix(".md.pre-optimize.bak")
    shutil.copy2(fix_plan, backup)

    lines = fix_plan.read_text().splitlines()

    # Build section → ordered unchecked task lines
    section_order: dict[str, list[str]] = {}
    for t in reordered_unchecked:
        section_order.setdefault(t.section, []).append(t.raw_line)

    output = _rebuild_lines(lines, section_order)

    tmp = fix_plan.with_suffix(".md.optimized.tmp")
    tmp.write_text("\n".join(output) + "\n")
    tmp.replace(fix_plan)


def _rebuild_lines(lines: list[str], section_order: dict[str, list[str]]) -> list[str]:
    """Rebuild file lines: preserve headers/checked/comments, replace unchecked per section."""
    output: list[str] = []
    current_section = ""
    section_inserted: set[str] = set()

    for line in lines:
        sec_match = _SECTION.match(line)
        if sec_match:
            current_section = sec_match.group(0)
            output.append(line)
            continue

        cb_match = _CHECKBOX.match(line)
        if not cb_match:
            output.append(line)
            continue

        checked = cb_match.group(1).lower() == "x"
        if checked:
            output.append(line)
        elif current_section not in section_inserted:
            # Insert all reordered unchecked tasks for this section
            output.extend(section_order.get(current_section, []))
            section_inserted.add(current_section)
        # else: skip remaining original unchecked lines (replaced above)

    return output


@dataclass
class OptimizeResult:
    """Result of plan optimization."""

    changed: bool = False
    reason: str = ""
    before: list[str] = field(default_factory=list)
    after: list[str] = field(default_factory=list)
    dependency_count: int = 0
