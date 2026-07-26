# T20 — README, troubleshooting, release checklist, icon

**Size:** S · **Model:** Sonnet · **Depends on:** all (final task) · **Milestone:** M4

## Goal
Ship-ready documentation and final polish once everything else is merged.

## Do
- `README.md` — replace the spec-phase status: feature overview with real screenshots (take them against a demo config; store in `docs/images/`), install/build instructions verified from a clean clone, the /Applications + FDA setup walkthrough (condensed from keychain-and-fda.md, linked for detail), FAQ (Why is my mirror stale? Why does the app need Full Disk Access? Where are passwords stored? What happens when my external drive is unplugged?).
- `docs/keychain-and-fda.md` — append a Troubleshooting section from *observed* behavior in T11/T18 PR evidence (what the badges showed, what fixed what) — replace speculation with findings.
- `docs/release.md` — manual release checklist: version bump locations, Developer ID signing + hardened runtime + `notarytool` submit/staple commands, the manual test checklists from testing.md §Layer 3 as a pre-release gate, `gh release create` with the zipped app.
- App icon: replace placeholder with a simple generated icon set (SF-symbol-derived or scripted; keep the source/script in `App/Resources/`); all required macOS sizes in the asset catalog.
- Sweep: every doc's commands re-run from a clean clone (`git clone && ./scripts/bootstrap.sh && …`); fix drift found; ensure `LICENSE` year/name intact; add `CONTRIBUTING.md` (two paragraphs: XcodeGen workflow, spec docs are normative — update docs with behavior changes).

## Acceptance criteria
- [ ] Clean-clone build following README alone succeeds on a machine/runner without prior setup.
- [ ] CI green; screenshots current; no TODO/placeholder text left in README or docs.
- [ ] `docs/release.md` dry-run performed at least through local signing (notarization optional if no Developer ID available; mark clearly).
