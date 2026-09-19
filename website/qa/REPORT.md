# Landing-page verification

Checked September 18, 2026 using the isolated gstack Chromium browser and Python static checks.

## Results

- `npm run build` passes. HTML is balanced; one main landmark and one h1; asset paths and fragment links resolve; six images have alt attributes and stable dimensions; no unresolved repository placeholders or invalid control characters.
- Local entrypoint responds HTTP 200. All six PNG assets decode successfully. No browser console errors.
- No horizontal overflow at viewport widths 320, 390, 768, 1024 and 1440px; also checked at 390px with root text size set to 200%.
- All nine visible button/footer-link touch targets are at least 44px tall.
- Keyboard Tab reveals “Skip to content”; Enter moves focus to main; next Tab focuses “Download for Mac” with a visible 3px outline.
- Phone screenshots preserve their source aspect ratio. Bottom CTA retains a distinct white-button hover treatment.
- GitHub API confirms the public repository, enabled issues, main-branch MIT license, and v0.1.1 prerelease with a universal Mac ZIP. This was the initial release-link check; download targets were subsequently updated as noted below. No ZIP was downloaded or executed.
- Independent source audit confirms all original marketing copy is preserved, aside from the intentional release line, and every supplied asset is byte-for-byte unchanged (SHA-256 comparison).
- At this initial local verification stage, only `website/` was changed and the site had not been deployed. No native app changes were made.

## Screenshots

- `desktop.png`: full page at 1440px wide.
- `desktop-hero.png`: first viewport at 1440 × 1000.
- `mobile.png`: full page at 390px wide.
- `mobile-small.png`: full page at 320px wide.
- `tablet.png`: full page at 768px wide.

Screenshots were inspected after image decoding. These checks cover this static landing page, not the functionality shown in the supplied native app mockups. Safari and physical-device testing were not performed.

## Download-link update

All three Mac download CTAs now use the user-supplied direct v0.1.2 universal ZIP URL, and the visible version is v0.1.2 preview. The saved screenshots document the initial v0.1.1 layout.

## Public deployment and custom domain

- PR #3 published the website through GitHub Pages. Deployment run `35418941095` succeeded, and the public page was checked in the browser with the v0.1.2 download and project GitHub links.
- `usetalaria.com` is registered in the owner's Porkbun account and configured as the repository's Pages custom domain.
- Public DNS resolves the apex to GitHub's four IPv4 and four IPv6 addresses. `www.usetalaria.com` resolves to `howhowdg.github.io`.
- GitHub's Pages health check reports both domains valid, served by Pages, and eligible for HTTPS. The apex returns HTTP 200. HTTPS certificate provisioning is pending at this checkpoint.
- Canonical and Open Graph URLs use `https://usetalaria.com/`; the social image uses an absolute URL on that domain. Static validation and `git diff --check` pass.
