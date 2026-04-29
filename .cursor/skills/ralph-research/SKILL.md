---
name: ralph-research
description: >
  Research the codebase before implementing a task. Use Grep/Glob, semantic
  search, or a read-only explore subagent to find relevant files, patterns,
  existing code, and test files.
---

Use the user's topic (or the current task text) as the research focus.

Search the codebase for:

1. Files related to the focus area
2. Existing implementations that might conflict or be reusable
3. Test files that will need updating
4. Import dependencies that might be affected

Return a structured summary:

### Related Files

- `path/to/file:line` — relevance description

### Existing Code to Reuse

- `FunctionName` in `path/to/file:line` — what it does

### Tests to Update

- `path/to/test_file` — what it tests

### Dependencies to Consider

- `package/module` — how it's used and what might break
