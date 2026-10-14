# AGENTS.md: .github/

`workflows/ci.yml`: the `ox-setup` composite action, `dune build`, `dune test`, the documentation build
with `ODOC_WARN_ERROR` (the step fails on any warning in the log), and the `obj-magic` reusable workflow.

- The documentation step is the same one the root AGENTS.md describes as `@venue-net/doc`; keep both in step.
- Check runs with `gh run list --limit 1`; at most one `gh run watch <id> --exit-status`. No loops.
