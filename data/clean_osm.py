#!/usr/bin/env python3
"""Merge + clean the Overpass karaoke pulls into one US venues CSV.

Reads osm_karaoke_us*.json (Overpass `out center tags`), dedupes by rounded
coordinate + normalized name, filters to the US, and writes venues.csv.
"""
import json, csv, glob, re, os

US_STATES = {
    'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA',
    'KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ',
    'NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT',
    'VA','WA','WV','WI','WY','DC','PR',
}
CA_PROV = {'ON','QC','BC','AB','MB','SK','NS','NB','NL','PE','NT','YT','NU'}
CA_CITIES = {'mississauga','toronto','vancouver','montreal','montréal','windsor',
             'ottawa','calgary','edmonton','winnipeg','hamilton','markham',
             'brampton','surrey','burnaby','richmond hill','scarborough','laval',
             'gatineau','victoria','quebec','québec','halifax','kitchener','london'}

def norm(s):
    return re.sub(r'\s+', ' ', (s or '')).strip()

rows = {}
for path in sorted(glob.glob(os.path.join(os.path.dirname(__file__), 'osm_karaoke_us*.json'))):
    data = json.load(open(path, encoding='utf-8'))
    for el in data.get('elements', []):
        t = el.get('tags', {})
        name = norm(t.get('name'))
        if not name:
            continue
        lat = el.get('lat') or (el.get('center') or {}).get('lat')
        lon = el.get('lon') or (el.get('center') or {}).get('lon')
        if lat is None or lon is None:
            continue
        state = (t.get('addr:state') or '').strip().upper()
        country = (t.get('addr:country') or '').strip().upper()
        # Exclude clearly-Canadian rows (bbox clips southern Canada).
        if country in ('CA', 'CANADA') or state in CA_PROV:
            continue
        if state and state not in US_STATES:
            continue
        # No US state on the row + a known Canadian city near the border → drop.
        if not state and norm(t.get('addr:city')).lower() in CA_CITIES:
            continue
        key = (round(lat, 4), round(lon, 4), name.lower())
        if key in rows:
            continue
        street = norm(' '.join(x for x in [t.get('addr:housenumber'), t.get('addr:street')] if x))
        rows[key] = {
            'name': name,
            'amenity': t.get('amenity') or t.get('leisure') or '',
            'address': street,
            'city': norm(t.get('addr:city')),
            'state': state,
            'postcode': norm(t.get('addr:postcode')),
            'phone': norm(t.get('phone') or t.get('contact:phone')),
            'website': norm(t.get('website') or t.get('contact:website')),
            'lat': round(lat, 6),
            'lon': round(lon, 6),
            'osm_type': el.get('type'),
            'osm_id': el.get('id'),
        }

out = os.path.join(os.path.dirname(__file__), 'venues.csv')
cols = ['name','amenity','address','city','state','postcode','phone','website','lat','lon','osm_type','osm_id']
with open(out, 'w', newline='', encoding='utf-8') as f:
    w = csv.DictWriter(f, fieldnames=cols)
    w.writeheader()
    for r in rows.values():
        w.writerow(r)

with_city = sum(1 for r in rows.values() if r['city'])
with_state = sum(1 for r in rows.values() if r['state'])
print(f"venues.csv: {len(rows)} unique US karaoke venues")
print(f"  with city: {with_city}   with state: {with_state}")
