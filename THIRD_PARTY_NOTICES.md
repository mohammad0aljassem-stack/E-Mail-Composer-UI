# Third-party notices

This project uses the following direct third-party packages. Each is used
under its own license; transitive dependencies carry their own licenses in the
`pnpm-lock.yaml` / installed package metadata. No third-party logos,
screenshots, proprietary assets, or AGPL-licensed source code are included in
this repository.

## Runtime dependencies

| Package                   | Version | License |
| ------------------------- | ------- | ------- |
| `next`                    | 16.2.10 | MIT     |
| `react`                   | 19.2.7  | MIT     |
| `react-dom`               | 19.2.7  | MIT     |
| `@tiptap/core`            | 2.27.2  | MIT     |
| `@tiptap/pm`              | 2.27.2  | MIT     |
| `@tiptap/react`           | 2.27.2  | MIT     |
| `@tiptap/starter-kit`     | 2.27.2  | MIT     |
| `@tiptap/extension-link`  | 2.27.2  | MIT     |
| `@react-email/components` | 1.0.12  | MIT     |
| `@react-email/render`     | 2.1.0   | MIT     |
| `sanitize-html`           | 2.17.6  | MIT     |

## Development dependencies

| Package                  | Version | License    |
| ------------------------ | ------- | ---------- |
| `typescript`             | 5.9.3   | Apache-2.0 |
| `eslint`                 | 9.39.5  | MIT        |
| `eslint-config-next`     | 16.2.10 | MIT        |
| `prettier`               | 3.9.5   | MIT        |
| `vitest`                 | 4.1.10  | MIT        |
| `@vitest/coverage-v8`    | 4.1.10  | MIT        |
| `@vitejs/plugin-react`   | 6.0.3   | MIT        |
| `@testing-library/react` | 16.3.2  | MIT        |
| `jsdom`                  | 29.1.1  | MIT        |
| `@types/node`            | 22.20.1 | MIT        |
| `@types/react`           | 19.2.17 | MIT        |
| `@types/react-dom`       | 19.2.3  | MIT        |
| `@types/sanitize-html`   | 2.16.1  | MIT        |

## Notes

- Architectural ideas discussed during design may draw on patterns from
  open-source e-mail projects, but **no source code from AGPL-licensed
  repositories (e.g. Inbox Zero, Kurrier) has been copied** into this project.
  Only original code is committed here.
- Licenses were read from each package's own metadata at install time
  (2026-07-11) and should be re-verified when versions change.
