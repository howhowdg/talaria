"""Validate the authored static output using only the Python standard library."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1] / "dist"
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}


class PageCheck(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []
        self.ids = set()
        self.fragments = []
        self.images = 0
        self.headings = 0
        self.main = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag not in VOID:
            self.stack.append(tag)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"Duplicate id: {attrs['id']}"
            self.ids.add(attrs["id"])
        if tag == "h1":
            self.headings += 1
        if tag == "main":
            self.main += 1
        if tag == "img":
            self.images += 1
            assert "alt" in attrs, "Image missing alt text"
            assert "width" in attrs and "height" in attrs, "Image dimensions missing"
        for attr in ["href", "src"]:
            if attr not in attrs:
                continue
            value = attrs[attr]
            assert "OWNER/" not in value, "Unresolved repository placeholder"
            url = urlparse(value)
            if value.startswith("#"):
                self.fragments.append(value[1:])
            elif not url.scheme:
                assert (ROOT / url.path).is_file(), f"Missing local asset: {value}"
            else:
                assert url.scheme == "https", f"Unexpected external URL: {value}"

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        assert self.stack and self.stack[-1] == tag, f"Mismatched closing {tag}: {self.stack}"
        self.stack.pop()


page = PageCheck()
html = (ROOT / "index.html").read_text()
assert not any(ord(char) < 32 and char not in "\n\r\t" for char in html), "Unexpected control character in HTML"
page.feed(html)
assert not page.stack, f"Unclosed elements: {page.stack}"
assert page.headings == 1 and page.main == 1, "Expected one h1 and one main landmark"
assert all(fragment in page.ids for fragment in page.fragments), "Broken fragment link"
assert page.images == 6, "Expected all six supplied images to be used"
print("Static build valid: balanced HTML, landmarks, six images, asset paths and links.")
