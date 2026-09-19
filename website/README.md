# Talaria landing page

Standalone static web app adapted from the supplied `Downloads/landing/dist/` design. All website work is contained in this directory; no native app source changes are required.

## Preview

Requires Python 3. npm is optional and only provides convenient command aliases; there are no packages to install.

```sh
cd website
npm run dev
```

Open <http://127.0.0.1:4173/>. The server serves only `dist/` and binds to loopback. Stop it with Ctrl-C.

Without npm:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory dist
```

## Validate

```sh
npm run build
# Equivalent: python3 scripts/check.py
```

`dist/` is the authored, ready-to-serve output. There is no transpilation or installation step. The build command validates HTML nesting, landmarks, image dimensions, all local asset references, internal links, and unresolved repository placeholders. Browser verification is documented in `qa/REPORT.md`.

## Files

- `dist/index.html`: semantic page structure, original marketing copy, links and metadata.
- `dist/styles.css`: supplied visual design with responsive and accessibility refinements.
- `dist/assets/`: all six original assets, unmodified.
- `DESIGN_REFERENCE.md`: the original design handoff notes.
- `qa/`: inspected screenshots and validation evidence.

## Hosting

The repository's `Publish Talaria website` GitHub Actions workflow validates pull requests and publishes `website/dist/` from `main`. It only runs automatically when public website files, the validator, or the workflow change. Native-only changes do not trigger website deployment. Enable GitHub Pages with **GitHub Actions** as the publishing source. The first deployment uses the project's GitHub Pages address until a registered custom domain is connected.

The deployment artifact excludes website documentation, QA captures, scripts and all native-app source. GitHub Releases continues to host the Mac download.

## Design and release decisions

The original composition, gradients, typography, winged-sandal artwork, Mac/iPhone mockups, sections and marketing copy are preserved. Responsive changes prevent narrow-screen clipping, preserve phone image proportions and stack actions at small widths. Semantic landmarks, a skip link, visible keyboard focus, 44px touch targets and stronger text/button contrast improve access.

Repository links resolve to `https://github.com/howhowdg/talaria`. All three Mac download buttons link directly to the user-supplied **v0.1.2 universal Mac ZIP**: `https://github.com/howhowdg/talaria/releases/download/v0.1.2/Talaria-0.1.2-macOS-universal.zip`. The displayed version is v0.1.2 preview. The page retains macOS 14+ and iPhone-in-development copy; no TestFlight date is promised.

The supplied product screenshots are design mockups and the copy describes the intended product experience. This implementation does not verify native feature availability. Keep screenshots and feature claims aligned with the shipping native build, refresh release links/version, and set absolute social metadata when the custom domain is connected.
