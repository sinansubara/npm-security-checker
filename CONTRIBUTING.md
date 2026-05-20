# Contributing

Thank you for taking the time to contribute.

## Ways to contribute

- **Report a false positive or false negative** — open an issue with the package name, version, and source (npm registry link or advisory reference).
- **Add a new compromised package** — the most common contribution; see below.
- **Improve the script** — bug fixes and behavioural improvements are welcome.

## Adding a compromised package

1. Fork the repository and create a branch: `git checkout -b advisory/package-name`.

2. Edit [`advisories/npm.json`](advisories/npm.json) or [`advisories/pip.json`](advisories/pip.json).

   **Package compromised at specific versions** — list only the exact versions that contain malicious code:
   ```json
   {
     "name": "package-name",
     "source": "https://link-to-advisory-or-blog-post",
     "compromised_versions": ["1.2.3", "1.2.4"]
   }
   ```

   **Package that is entirely fake/malicious** — omit `compromised_versions` entirely; any installed version will be flagged:
   ```json
   {
     "name": "fake-package-name",
     "source": "https://link-to-advisory-or-blog-post"
   }
   ```

   **Multiple packages from the same incident** — add a `references` array at the top of the file and a `source` on each entry:
   ```json
   {
     "schema": 1,
     "updated": "2026-05-20",
     "references": [
       "https://link-to-incident-report"
     ],
     "packages": [
       { "name": "pkg-a", "source": "https://...", "compromised_versions": ["1.0.0"] },
       { "name": "pkg-b", "source": "https://..." }
     ]
   }
   ```

   Guidelines:
   - Use the exact registry name (case-sensitive for npm; match canonical casing for pip).
   - List only versions confirmed to contain **malicious code** — do **not** list versions that are merely vulnerable (CVE-style); this tool targets supply-chain compromises (malware injected into a release).
   - Always include a `source` URL pointing to the advisory, blog post, or GitHub issue that confirms the compromise.
   - Update the `"updated"` date at the top of the file.

3. Validate the JSON is well-formed:
   ```bash
   python3 -c "import json; json.load(open('advisories/npm.json')); print('OK')"
   ```

4. Open a pull request against `master`. The PR description should include the source link and a one-line summary of the incident.

## Reporting an issue

Please include:
- OS and Bash version (`bash --version`)
- The exact command you ran
- The output (redact any sensitive paths if needed)
- What you expected vs. what happened

## Code style

- Bash: follow the existing style — 2-space indent, `[[ ]]` for tests, `local` for function variables, no unnecessary subshells.
- JSON: 2-space indent, trailing newline, no comments.
- Keep the script self-contained — no new runtime dependencies.

## License

By contributing you agree that your contributions will be licensed under the [MIT License](LICENSE).
