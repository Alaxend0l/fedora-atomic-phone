<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Contributing

## Adding a phone
Start with [docs/porting.md](docs/porting.md). A port is one folder under
`devices/`; run `just DEVICE=<id> check` before opening a PR.

## Commits
- One logical change per commit, with a message that says why.
- Hardware claims in device READMEs should say how they were verified
  (logs, a command, a datasheet), or be marked "to check".

## AI-assisted contributions (draft)
AI tools are allowed, on the same terms as Fedora's
[AI-Assisted Contributions Policy](https://docs.fedoraproject.org/en-US/council/policy/ai-contribution-policy/):
- You're responsible for what you submit: read it, test it, and be able to
  explain it. Unreviewed generated output isn't accepted.
- Disclose significant AI help in the commit message with a trailer, e.g.
  `Assisted-by: <tool>` or `Co-Authored-By: <tool>`.
- Don't paste output you can't license under this project's terms.

This project itself is developed with AI assistance (Claude), reviewed by the
maintainer; commits say so.

## License
Not chosen yet (repository is private). Until it is, contributions aren't
being accepted from outside.
