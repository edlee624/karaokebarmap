#!/usr/bin/env python3
"""Generate public/sitemap.xml + robots.txt from the live venue slugs.
Pulls slugs from Supabase REST (all listings are publicly readable via RLS)."""
import os, json, urllib.request

BASE = 'https://karaokebarmap.com'
SUPA = 'https://hjdycgzcfynijzqnbujq.supabase.co'
KEY = 'sb_publishable_wsci1jNeI_wGl5yX525Sfw_7s6q_YWn'
OUT = os.path.join(os.path.dirname(__file__), '..', 'public')

# Static routes the SPA serves.
static = ['/', '/terms', '/privacy']

# Fetch every listing slug (paged; PostgREST caps at 1000/req by default).
slugs, offset = [], 0
while True:
    req = urllib.request.Request(
        f'{SUPA}/rest/v1/salons?select=slug&order=slug&limit=1000&offset={offset}',
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'})
    rows = json.load(urllib.request.urlopen(req, timeout=30))
    slugs += [r['slug'] for r in rows if r.get('slug')]
    if len(rows) < 1000:
        break
    offset += 1000

def esc(u):
    return u.replace('&', '&amp;')

urls = static + ['/' + s for s in slugs]
with open(os.path.join(OUT, 'sitemap.xml'), 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    f.write('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n')
    for u in urls:
        loc = esc(BASE + u)
        pr = '1.0' if u == '/' else ('0.5' if u in static else '0.7')
        f.write(f'  <url><loc>{loc}</loc><changefreq>weekly</changefreq><priority>{pr}</priority></url>\n')
    f.write('</urlset>\n')

with open(os.path.join(OUT, 'robots.txt'), 'w', encoding='utf-8') as f:
    f.write('User-agent: *\nAllow: /\n\n')
    f.write(f'Sitemap: {BASE}/sitemap.xml\n')

print(f'sitemap.xml: {len(urls)} urls ({len(slugs)} venues + {len(static)} static)')
print('robots.txt written')
