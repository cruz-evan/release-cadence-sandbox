# Private release cadence sandbox

This repository tests release automation copied from `evan/weekly-release-cadence`
at commit `b4800626e5` in Cronometer Flutter. It contains no app source, app history,
signing keys, or production distribution credentials.

The four Dart scripts, two Ruby helpers, and Release Drafter configuration are
copied unchanged. Sandbox workflow changes: schedules removed; standalone Dart
setup; `CODE_WRITE_TOKEN` falls back to the repository `GITHUB_TOKEN`; PR write
permission enabled. Manual build only records requested inputs in a JSON artifact.

## Repeat a release test

Use a local clone with Dart, Node 24+, npx, Ruby, Git and the GitHub CLI.
Run `python3 sandbox.py cut YYYY-MM-DD` with a Sunday date.
Merge a fixture fix PR into the release branch and check its draft release notes.
Run `python3 sandbox.py beta YYYY-MM-DD` for a simulated Friday build.
Run `python3 sandbox.py finish YYYY-MM-DD FULL_APPROVED_SHA` to pin the tag
and open the release merge PR, then merge that PR to test automatic publication.

`sandbox.py` loads the CLI credential into its child process environment only;
it does not persist or print the token. It refuses to target another repository.

Actions can also run manually. With the default `GITHUB_TOKEN`, automation-created
pushes do not trigger the release-notes workflow; local CLI operations exercise
that event chain. For full workflow-to-workflow fidelity, configure a separately
scoped sandbox-only `CODE_WRITE_TOKEN`. Do not copy the production token.

Builds are placeholders. Passing this test does not validate app compilation,
signing, uploads, store promotion, production token permissions, or schedules.
