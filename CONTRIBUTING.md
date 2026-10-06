# Contributing to PreviewMD

Thank you for spending your time on PreviewMD. Whether you bring a one-line
documentation fix, a pathological Markdown file, a UI refinement, or the first
credible experiment on another operating system, you are welcome here.

## The short version

1. Search existing issues and discussions.
2. For a substantial change, open an issue before writing the full patch.
3. Fork the repository and create a focused branch.
4. Make the change and add or update tests.
5. Run the relevant checks.
6. Sign off every commit with `git commit -s`.
7. Open a pull request and explain the user-visible result.

Small, complete pull requests are easier to review and more likely to land
quickly. A contribution does not need to be large to be important.

## Good first contributions

You can help without knowing Swift or AppKit:

- reduce a bug report to a tiny reproduction document;
- improve the README, porting guide, or deployment documentation;
- check keyboard-only and VoiceOver behavior;
- add a regression test for a renderer edge case;
- improve landing-page accessibility or copy;
- verify a release on a different supported Mac;
- triage an issue and identify the smallest next step.

Issues labeled `good first issue` should include enough context to begin. If one
does not, ask — that is useful feedback about the issue itself.

## Before a larger change

Please open an issue before starting work that introduces a dependency, changes
an established product behavior, restructures a subsystem, adds a file format,
or begins a platform port. Describe:

- the user problem;
- the smallest useful outcome;
- the proposed approach;
- alternatives you considered;
- how you will test it.

This is not a permission ritual. It is how we avoid parallel work, uncover
constraints early, and help a promising idea find the right boundary.

## Development setup

The current application target requires macOS 14 or newer and Xcode with Swift
6.1 support. It is a Swift Package Manager project with no `.xcodeproj`.

```bash
git clone https://github.com/ashtree74/PreviewMD.git
cd PreviewMD
swift test
swift run PreviewMD
```

Useful checks:

```bash
swift test
python3 -m unittest discover -s site -p 'test_*.py'
node --test Tests/Site/signup.test.cjs
zsh -n scripts/*.sh
./scripts/build-app.sh
```

The complete app-bundle build is slower than `swift test`, so use it when your
change affects resources, packaging, icons, Info.plist values, signing, or the
Quick Look extension. It produces an ad-hoc signed Universal 2 app without
requiring maintainer credentials.

## Project invariants

PreviewMD has deliberate product behaviors around windows, tabs, folders,
focus mode, layout, offline rendering, Quick Look, and releases. Read
[`AGENTS.md`](AGENTS.md) before changing application behavior. These invariants
are constraints, not mysteries; if one seems wrong, propose changing it in an
issue with the user problem and migration path.

In particular:

- rendering must continue to work offline;
- documents must not be uploaded or silently tracked;
- local images and relative links must remain local and useful;
- native macOS surfaces should stay native;
- bundled third-party notices must ship with every binary;
- release builds must remain Universal 2.

## Tests and reviewability

Prefer a failing test before a bug fix when the behavior can be isolated.
Native and renderer tests live in `Tests/PreviewMDTests/`. Server tests live in
`site/test_server.py`; signup lifecycle tests execute the actual modal JavaScript
from `Tests/Site/signup.test.cjs`, outside the public document root.

In a pull request, include:

- what changed for the user;
- why this is the right-sized solution;
- tests you ran;
- screenshots or a short recording for visible UI changes;
- known limitations or follow-up work.

Keep refactors separate from behavior changes where practical. Do not rewrite
unrelated code or generated vendored files as part of a focused fix.

## Renderer and dependency updates

The document renderer is intentionally bundled. Do not replace offline assets
with CDN calls or add runtime network requirements.

When upgrading a vendored library:

1. update its pinned browser distribution;
2. update its version, copyright, and complete license text in
   `Sources/PreviewMD/Acknowledgements.swift`;
3. update `THIRD_PARTY_NOTICES.md`;
4. run `swift test` so the acknowledgement checks verify the shipped version.

Do not submit minified third-party code without a clear upstream source,
version, checksum, and compatible license.

## Platform ports

Ports are encouraged, but a new native shell should begin as a thin experiment,
not a rewrite of the working macOS app. Read [`docs/PORTING.md`](docs/PORTING.md)
and open a port proposal using the GitHub issue template.

The PreviewMD name and icon identify the official project. Prototypes may
describe themselves as PreviewMD port experiments, but public distributions
must follow [`TRADEMARKS.md`](TRADEMARKS.md).

## Commit sign-off and the DCO

PreviewMD uses the [Developer Certificate of Origin 1.1](DCO), not a copyright
assignment. You retain copyright in your contribution and certify that you have
the right to submit it under the project's Apache-2.0 license.

Sign each commit with:

```bash
git commit -s
```

Git adds a line like:

```text
Signed-off-by: Your Name <you@example.com>
```

Use your real name or an established identity you are comfortable associating
permanently with the public contribution. If you forgot the sign-off on your
latest local commit, use `git commit --amend -s --no-edit`.

## Licensing and generated work

Unless explicitly stated otherwise, intentionally submitted contributions are
licensed under [Apache-2.0](LICENSE). You are responsible for ensuring that your
work is original or compatibly licensed and that required attribution is
included.

Development tools, including generative tools, are welcome. They do not take
responsibility for the patch: review their output, test it, check provenance,
and do not submit material you cannot license under Apache-2.0.

## Community

Be kind, concrete, and curious. Critique the change, never the person. Assume
good intent while still asking for evidence. The full expectations are in
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

Security vulnerabilities should not be reported in a public issue. Follow
[`SECURITY.md`](SECURITY.md) instead.
