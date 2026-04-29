---
title: Ralph user guide
description: Hands-on tutorials for new users — quick start, file reference, and requirements writing.
audience: [user]
diataxis: tutorial
last_reviewed: 2026-04-23
---

# Ralph user guide

This guide helps you get started with Ralph and understand how to configure it effectively for your projects. Read in order; each guide builds on the last.

## Guides

### [Quick Start: Your First Ralph Project](01-quick-start.md)
A hands-on tutorial that walks you through enabling Ralph on an existing project and running your first autonomous development loop. You'll build a simple CLI todo app from scratch.

### [Understanding Ralph Files](02-understanding-ralph-files.md)
Learn which files Ralph creates, which ones you should customize, and how they work together. Includes a complete reference table and explanations of file relationships.

### [Writing Effective Requirements](03-writing-requirements.md)
Best practices for writing PROMPT.md, when to use specs/, and how fix_plan.md evolves during development. Includes good and bad examples.

### Design specs (Ralph repository)

Loop reliability, tool permissions, and roadmap notes for **Ralph itself** live in the repo’s **[`docs/specs/`](../specs/)** directory (epics, user stories, RFC). That is separate from **`.ralph/specs/`** inside your project (your product requirements).

## Example Projects

Check out the [examples/](../../examples/) directory for complete, realistic project configurations:

- **[simple-cli-tool](../../examples/simple-cli-tool/)** - Minimal example showing core Ralph files
- **[rest-api](../../examples/rest-api/)** - Medium complexity with specs/ directory usage

## Quick Reference

| I want to... | Do this |
|-------------|---------|
| Check installed Ralph version | `ralph --version` |
| Enable Ralph on an existing project | `ralph-enable` |
| Import a PRD/requirements doc | `ralph-import requirements.md project-name` |
| Create a new project from scratch | `ralph-setup my-project` |
| Start Ralph with monitoring | `ralph --monitor` |
| Check what Ralph is doing | `ralph --status` |

## Need Help?

- **[Main README](../../README.md)** - Full documentation and configuration options
- **[CONTRIBUTING.md](../../CONTRIBUTING.md)** - How to contribute to Ralph
- **[GitHub Issues](https://github.com/wtthornton/ralph-claude-code/issues)** - Report bugs or request features
