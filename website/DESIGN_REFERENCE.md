# Talaria landing page

Static site — no build step. Open `index.html` or drop the folder on any static host (GitHub Pages, Netlify, Vercel, Cloudflare Pages).

## Before publishing
Search-and-replace `OWNER/talaria` in `index.html` with your GitHub org/repo. Links used:
- `https://github.com/OWNER/talaria` — repo (GitHub buttons)
- `https://github.com/OWNER/talaria/releases/latest` — Download for Mac
- `https://github.com/OWNER/talaria/issues` — Issues
- `https://github.com/OWNER/talaria/blob/main/LICENSE` — License

Also update: the release note text (`v0.1 · macOS 15+`), the licence name (`MIT`), and the four screenshots in `assets/` once real-build captures exist (`mac-home.png` 2360×1520, `ios-home.png` / `ios-activity.png` 804×1748).

## GitHub Pages
Copy `index.html` + `assets/` into a `docs/` folder on the default branch, then Settings → Pages → Deploy from branch → `/docs`. Relative asset paths work as-is.

## Files
- `index.html` — the page, inline styles, no JS, no dependencies
- `assets/` — mark (ink / white), Mac and iPhone screenshots
