## What changed

<!-- One paragraph. What behavior differs after this PR? -->

## Review anchor

An independent review applies to an exact `(base SHA, head SHA)` pair. Changing
the base can change the diff even when the head commit is identical, so these
must be filled in and **re-stated after any rebase, force-push, or retarget** —
a review against a superseded pair does not carry forward.

- Base SHA: `<full sha>`
- Head SHA: `<full sha>`
- Reviewed at this pair: <!-- pending / passed / findings addressed in <sha> -->

## Checklist

- [ ] Spec docs in `docs/` updated in this PR if behavior changed (they are normative)
- [ ] `project.yml` edited rather than `ResticStation.xcodeproj` (it is generated)
- [ ] `Core/` and `Helper/` still build and test on Linux
- [ ] Invariants preserved — see CONTRIBUTING.md; destructive-path changes name which one they touch
- [ ] Destructive-path change? State the failure direction if the new code is wrong.
- [ ] Behavior change? Blast radius swept — docs, task specs, UI copy, error envelopes, and test assertions all describe the post-change world
- [ ] New/changed assertions red-checked (each demonstrably fails against the pre-change behavior)
- [ ] New or extended safety invariant? Threat-model scenarios (concurrent processes, crash points, legacy state, PID reuse) stated in the description
