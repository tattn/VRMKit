# Contributing to VRMKit

Thank you for your interest in VRMKit. This project is maintained by a single person with limited time for review. The rules below exist so that contributions can be reviewed and merged reliably within that time. Pull requests that do not follow them may be closed regardless of their content.

## Discuss large changes in an issue first

Unless your change is a bug fix, a typo fix in the documentation, or a minor suggestion, open an issue and agree on the approach before writing a pull request. The following always require prior discussion:

- New features, or additions or changes to the public API
- Changes to how rendering or loading works
- Changes to dependencies, supported OS versions, or the Swift version
- Changes to the directory layout or build configuration

If a large pull request arrives without prior discussion and its design does not match the direction of the project, none of it can be accepted. Reach agreement in an issue before you start implementing.

## One pull request, one purpose

- Solve exactly one problem per pull request. Put "while I was at it" changes in separate pull requests
- Keep the change under 300 lines as a guideline, and under 500 lines at most. If it has to be larger, propose how to split it in an issue first
- Pull requests that bundle several changes, bring over the state of a fork as is, or resolve several issues at once will not be accepted
- Keep refactoring separate from feature work

## Checklist before opening a pull request

- [ ] The description links the related issue (for example `Closes #123`)
- [ ] The change has a single, focused purpose
- [ ] The branch is rebased on the latest `main`
- [ ] `swift test` passes
- [ ] Tests covering the changed behavior are added or updated
- [ ] No new compiler warnings are introduced
- [ ] No unrelated files are included (`.gitignore`, formatting-only diffs, generated files, and so on)
- [ ] The README is updated if the public API changed
- [ ] The result has been checked visually on the affected platforms
- [ ] If the change affects rendering, a screenshot for every affected platform is attached to the pull request

## Code

- Match the style, naming, and comment density of the surrounding code
- Write comments only where they explain why something is done. Comments that describe what the code does, or what was changed, are not needed
- Do not leave commented-out code behind
- If you change the MToon shaders in `Sources/VRMRealityKit/Shaders/`, run `scripts/build-mtoon-metallibs.sh` to regenerate the metallibs and make sure `--check` passes. Do not include metallib diffs in a pull request that does not change the shaders

## Testing

- macOS: `swift test`
- All platforms: `make test` (requires the simulators for each platform)
- Example apps: `make build-examples`

CI runs the tests on iOS, macOS, watchOS, and visionOS once the maintainer approves the workflow run. Pull requests with failing CI will not be reviewed.

If the change affects rendering, attach a screenshot for every platform it affects. A rendering change without screenshots cannot be reviewed.

## Changes made with AI tools

Using AI tools is not prohibited, but the following applies:

- Before submitting, read, understand, and verify every line of the change yourself. Do not submit changes you cannot explain
- Do not submit large AI-generated changes as they are. The size and scope limits above apply unchanged
- Claims such as "tested" or "verified" in the pull request description must describe what you actually did yourself
- If you used an AI tool, mention it in the pull request description or in a commit trailer. This is not required, but it helps the review

## Review

- Review can take time. Please refrain from posting reminders while waiting for a reply
- A change may be declined because it does not fit the direction of the project, or because its maintenance cost outweighs its benefit
- Pull requests that receive no reply or update for an extended period will be closed

## License

By contributing, you agree that your contribution is released under the project's [license](./LICENSE).
