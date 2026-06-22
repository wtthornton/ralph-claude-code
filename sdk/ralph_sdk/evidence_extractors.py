"""Test/lint evidence models and best-effort extraction helpers.

Split out of ralph_sdk.evidence: the TestEvidence/LintEvidence models plus
the regex-based extractors that parse pytest/jest/BATS/ruff/eslint output.
"""

from __future__ import annotations

import re

from pydantic import BaseModel


class TestEvidence(BaseModel):
    """Extracted test execution results."""
    framework: str = ""
    total: int = 0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    errors: int = 0
    raw_output: str = ""


class LintEvidence(BaseModel):
    """Extracted lint/formatting results."""
    tool: str = ""
    errors: int = 0
    warnings: int = 0
    raw_output: str = ""


def _extract_test_results(output: str) -> list[TestEvidence]:
    """Best-effort extraction of test results from raw output."""
    results = []

    # pytest: "= X passed, Y failed, Z skipped in Ns =" (requires = delimiter or "in Xs")
    pytest_pattern = r'=+\s*(\d+)\s+passed(?:,\s*(\d+)\s+failed)?(?:,\s*(\d+)\s+skipped)?(?:,\s*(\d+)\s+error)?'
    for match in re.finditer(pytest_pattern, output, re.IGNORECASE):
        passed = int(match.group(1))
        failed = int(match.group(2) or 0)
        skipped = int(match.group(3) or 0)
        errors = int(match.group(4) or 0)
        results.append(TestEvidence(
            framework="pytest",
            total=passed + failed + skipped + errors,
            passed=passed,
            failed=failed,
            skipped=skipped,
            errors=errors,
            raw_output=match.group(0).strip(),
        ))

    # jest: "Tests:  X passed, Y failed, Z total" or "Test Suites: X passed"
    jest_pattern = r'Tests:\s+(?:(\d+)\s+failed,\s*)?(\d+)\s+passed(?:,\s*(\d+)\s+total)?'
    for match in re.finditer(jest_pattern, output, re.IGNORECASE):
        failed = int(match.group(1) or 0)
        passed = int(match.group(2))
        total = int(match.group(3) or (passed + failed))
        results.append(TestEvidence(
            framework="jest",
            total=total,
            passed=passed,
            failed=failed,
            raw_output=match.group(0).strip(),
        ))

    # BATS: "X tests, Y failures" or "ok X - test name"
    bats_pattern = r'(\d+)\s+tests?,\s*(\d+)\s+failures?'
    for match in re.finditer(bats_pattern, output, re.IGNORECASE):
        total = int(match.group(1))
        failed = int(match.group(2))
        results.append(TestEvidence(
            framework="bats",
            total=total,
            passed=total - failed,
            failed=failed,
            raw_output=match.group(0).strip(),
        ))

    return results


def _extract_lint_results(output: str) -> list[LintEvidence]:
    """Best-effort extraction of lint results from raw output."""
    results = []

    # ruff: "Found X errors" or "X errors fixed"
    ruff_pattern = r'(?:Found\s+)?(\d+)\s+error'
    ruff_warn_pattern = r'(\d+)\s+warning'
    for match in re.finditer(ruff_pattern, output):
        # Only match if "ruff" appears nearby
        context_start = max(0, match.start() - 200)
        context = output[context_start:match.end() + 100]
        if "ruff" in context.lower():
            errors = int(match.group(1))
            warns = 0
            warn_match = re.search(ruff_warn_pattern, context)
            if warn_match:
                warns = int(warn_match.group(1))
            results.append(LintEvidence(
                tool="ruff",
                errors=errors,
                warnings=warns,
                raw_output=match.group(0).strip(),
            ))

    # eslint: "X problems (Y errors, Z warnings)"
    eslint_pattern = r'(\d+)\s+problems?\s*\((\d+)\s+errors?,\s*(\d+)\s+warnings?\)'
    for match in re.finditer(eslint_pattern, output, re.IGNORECASE):
        results.append(LintEvidence(
            tool="eslint",
            errors=int(match.group(2)),
            warnings=int(match.group(3)),
            raw_output=match.group(0).strip(),
        ))

    return results
