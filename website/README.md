# Talaria website

Static landing page for [usetalaria.com](https://usetalaria.com/). The public files live in `dist/`; there are no package dependencies or compilation step.

## Preview

Requires Python 3. From this directory:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory dist
```

Open <http://127.0.0.1:4173/>. `npm run dev` runs the same command.

## Check changes

```sh
python3 scripts/check.py
# Or: npm run build
```

The check validates HTML structure, landmarks, image dimensions, local assets and internal links. For layout changes, also check desktop and narrow mobile widths, keyboard navigation and enlarged text in a browser.

## Publish

The `Publish Talaria website` GitHub Actions workflow validates website pull requests and publishes only `website/dist/` from `main`. It runs when public website files, the validator or the workflow change. GitHub Releases hosts the Mac download.

GitHub Pages uses `usetalaria.com` as its custom domain. Porkbun DNS points the apex A and AAAA records to GitHub Pages, with `www` as a CNAME to `howhowdg.github.io`. Actions publishing uses the domain configured in Pages settings and does not require a `CNAME` file.

Keep the three download links and displayed version aligned with the current release. Canonical and social-image URLs use `https://usetalaria.com/`. The supplied product images are design previews; update them as the native interface evolves.
