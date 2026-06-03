#!/usr/bin/env python3
"""
Fix all monday-*.html mocks:
1. All emoji already stripped (128 across 11 files)
2. Add inline SVG icons in place of empty spans/buttons that had emoji
3. Add GDPR footer SVGs
4. For automations: add SimpleIcons CDN for brand logos
"""

import os, re, glob

mocks_dir = "/Users/jocham/programming/openclaw/ux-designer/mocks"

# ===== SVG Icon Library (HugeIcons-style, 24x24) =====

def svg(name):
    """Return inline SVG for common icon names."""
    icons = {
        # GDPR / data
        "shield": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>',
        "download": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>',
        "trash": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>',
        "settings": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>',
        "file": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/></svg>',
        "calendar": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/></svg>',
        # Actions
        "logs": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg>',
        "terminal": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/></svg>',
        "activity": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>',
        "brain": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2a2 2 0 012 2v2h3a3 3 0 013 3v9a3 3 0 01-3 3H7a3 3 0 01-3-3V9a3 3 0 013-3h3V4a2 2 0 012-2z"/></svg>',
        "plus": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>',
        "search": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>',
        "bell": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/></svg>',
        "check": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>',
        "x": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>',
        "copy": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>',
        "edit": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16.5 3.5a2.121 2.121 0 013 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>',
        "star": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>',
        "play": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"/></svg>',
        "pause": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg>',
        "stop": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="2"/></svg>',
        "refresh": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 4v6h6"/><path d="M3.5 15.5A8 8 0 1 0 5 7L1 10"/></svg>',
        "menu": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="18" x2="21" y2="18"/></svg>',
        "list": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg>',
        "grid": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg>',
        "heart": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>',
        "message": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>',
        "send": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>',
        "user": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
        "home": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
        "tag": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z"/><line x1="7" y1="7" x2="7.01" y2="7"/></svg>',
    }
    return icons.get(name, "")

def wrap_svg(svg_html, cls="", size=16):
    """Wrap SVG in a span with standard icon styling."""
    return f'<span class="{cls}" style="display:inline-flex;align-items:center;justify-content:center;width:{size}px;height:{size}px;flex-shrink:0;vertical-align:middle;">{svg_html}</span>' if cls else f'<span style="display:inline-flex;align-items:center;justify-content:center;width:{size}px;height:{size}px;flex-shrink:0;vertical-align:middle;">{svg_html}</span>'

# ===== Fix files =====

# Common replacements: empty .tb-btn, .gdpr-item, etc. that had emoji removed
replacement_patterns = [
    # GDPR footer in its various forms
    ('class="tb-btn"> Logs</button>', f'class="tb-btn">{wrap_svg(svg("logs"), size=14)} Logs</button>'),
    ('class="tb-btn"> Terminal</button>', f'class="tb-btn">{wrap_svg(svg("terminal"), size=14)} Terminal</button>'),
    ('class="tb-btn"> Events</button>', f'class="tb-btn">{wrap_svg(svg("activity"), size=14)} Events</button>'),
    ('style="background:#6C31FF;color:#fff;border-color:#6C31FF;"> Debug with AI</button>',
     f'style="background:#6C31FF;color:#fff;border-color:#6C31FF;">{wrap_svg(svg("brain"), size=14)} Debug with AI</button>'),
    # Generic empty spans that were emoji
    ('class="gdpr-foot">\n      <span style="font-size:11px;font-weight:600;color:#444;"> Data &amp; Privacy</span>',
     f'<div class="gdpr-foot">\n      <span style="font-size:11px;font-weight:600;color:#444;">{wrap_svg(svg("shield"), size=14)} Data &amp; Privacy</span>'),
    (' Data &amp; Privacy</span>\n      <span class="gdpr-item" role="button" tabindex="0"> Export My Data</span>',
     f' Data &amp; Privacy</span>\n      <span class="gdpr-item" role="button" tabindex="0">{wrap_svg(svg("download"), size=14)} Export My Data</span>'),
    ('span class="gdpr-item" role="button" tabindex="0"> Delete My Data</span>',
     f'span class="gdpr-item" role="button" tabindex="0">{wrap_svg(svg("trash"), size=14)} Delete My Data</span>'),
    ('span class="gdpr-item" role="button" tabindex="0"> Consent Preferences</span>',
     f'span class="gdpr-item" role="button" tabindex="0">{wrap_svg(svg("settings"), size=14)} Consent Preferences</span>'),
    ('span class="gdpr-item" role="button" tabindex="0"> Audit Log</span>',
     f'span class="gdpr-item" role="button" tabindex="0">{wrap_svg(svg("file"), size=14)} Audit Log</span>'),
    ('span class="gdpr-item" style="cursor:default;"> Retention: 90 days <span class="gdpr-badge">GDPR</span></span>',
     f'span class="gdpr-item" style="cursor:default;">{wrap_svg(svg("calendar"), size=14)} Retention: 90 days <span class="gdpr-badge">GDPR</span></span>'),
]

# Process each monday-*.html file
files = sorted(glob.glob(os.path.join(mocks_dir, "monday-*.html")))
fixes = 0
for fpath in files:
    fname = os.path.basename(fpath)
    with open(fpath, "r") as f:
        content = f.read()

    # Skip files already fully processed (agents + create-agent have SVGs already)
    # Check if GDPR footer already has an SVG icon
    if fname in ("monday-agents.html", "monday-create-agent.html"):
        print(f"{fname}: already processed, skipping")
        continue

    original = content
    for pattern, replacement in replacement_patterns:
        # Only apply if the pattern exists
        if pattern in content:
            # Check the replacement isn't already there
            # (in case a partial previous run happened)
            content = content.replace(pattern, replacement, 1)

    # Fix generic empty GDPR footer patterns (different formatting in some files)
    # Some have no newline after gdpr-foot
    content = content.replace(
        '<span style="font-size:11px;font-weight:600;color:#444;"> Data &amp; Privacy</span>',
        f'<span style="font-size:11px;font-weight:600;color:#444;">{wrap_svg(svg("shield"), size=14)} Data &amp; Privacy</span>'
    )

    if content != original:
        fixes += 1
        with open(fpath, "w") as f:
            f.write(content)
        print(f"{fname}: applied icon replacements")

print(f"\nFixed {fixes} files. Skipped: {len(files) - fixes - 2} (clean)")

# ===== Add SimpleIcons CDN script to automations page =====
automations_path = os.path.join(mocks_dir, "monday-automations.html")
if os.path.exists(automations_path):
    with open(automations_path, "r") as f:
        content = f.read()
    # Add SimpleIcons CDN link before </head>
    simple_cdn = '<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/simple-icons@11/font/simple-icons.min.css">\n'
    if 'simple-icons' not in content:
        content = content.replace('</head>', f'{simple_cdn}</head>')
        # Also replace brand emoji-like patterns
        # Look for Slack/Jira/GitHub/Confluence references with empty spans
        content = content.replace(
            'class="si" style="background:#611F69;color:#fff;"><span style="font-size:12px;"></span></div>',
            'class="si" style="background:#611F69;color:#fff;"><i class="si si-slack" style="font-size:14px;"></i></div>'
        )
        content = content.replace(
            'class="si" style="background:#0052CC;color:#fff;"><span style="font-size:12px;"></span></div>',
            'class="si" style="background:#0052CC;color:#fff;"><i class="si si-jira" style="font-size:14px;"></i></div>'
        )
        content = content.replace(
            'class="si" style="background:#24292F;color:#fff;"><span style="font-size:12px;"></span></div>',
            'class="si" style="background:#24292F;color:#fff;"><i class="si si-github" style="font-size:14px;"></i></div>'
        )
        content = content.replace(
            'class="si" style="background:#172B4D;color:#fff;"><span style="font-size:12px;"></span></div>',
            'class="si" style="background:#172B4D;color:#fff;"><i class="si si-confluence" style="font-size:14px;"></i></div>'
        )
        # Google: use si-googlegemini or si-google
        content = content.replace(
            'style="background:#4285F4;color:#fff;"><span style="font-size:12px;"></span></div>',
            'style="background:#4285F4;color:#fff;"><i class="si si-google" style="font-size:14px;"></i></div>'
        )
        # monday.com
        content = content.replace(
            'class="si" style="background:#2559D6;color:#fff;"><span style="font-size:12px;"></span></div>',
            'class="si" style="background:#2559D6;color:#fff;"><i class="si si-monday" style="font-size:14px;"></i></div>'
        )
        with open(automations_path, "w") as f:
            f.write(content)
        print("automations: added SimpleIcons CDN + brand icons")
    else:
        print("automations: already has SimpleIcons")
else:
    print("automations: not found")

print("\nDone.")
