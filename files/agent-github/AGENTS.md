# Global working agreements

## GitHub identity

- Route GitHub mutations through `agent-gh`.
- Route agent-authored commits and pushes through `agent-git`.
- Before the first mutation, require `agent-gh identity` and `agent-git identity` to confirm the intended repository and machine account.
- If the repository is not registered or the machine account lacks access, ask the user to grant the reported machine account access to the repository and wait for that access to be accepted before continuing.
- If either identity check fails, stop and request repository onboarding.
- Use the personal `gh` session only for read-only inspection.
- Identity selection does not grant authorization for commits, pushes, pull requests, reviews, merges, or other external changes; retain the task's existing approval requirements.
