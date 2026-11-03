#!/usr/bin/env python3
"""Build a self-contained offline reader from the documentation Markdown files."""
from pathlib import Path
import re, html
ROOT = Path(__file__).resolve().parent.parent
FILES = ['README.md','QUICK-START.md','WHITE-PAPER.md','ENGINEERING.md','LIMITATIONS.md','VALIDATION.md','CHANGELOG.md','SOURCES.md']
def slug(s): return re.sub(r'[^a-z0-9]+','-', re.sub(r'<[^>]+>','',s).lower()).strip('-')
def inline(s):
    s=html.escape(s, quote=False)
    s=re.sub(r'`([^`]+)`',r'<code>\1</code>',s)
    s=re.sub(r'\*\*([^*]+)\*\*',r'<strong>\1</strong>',s)
    s=re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)',r'<em>\1</em>',s)
    def image(m):
        alt,path=m.group(1),m.group(2)
        asset=(ROOT/path).resolve()
        if asset.is_file() and ROOT in asset.parents and asset.suffix == '.svg':
            return '<figure>'+asset.read_text()+'<figcaption>'+alt+'</figcaption></figure>'
        return '<span>'+alt+'</span>'
    s=re.sub(r'!\[([^]]*)\]\(([^)]+)\)',image,s)
    def link(m):
        label,url=m.group(1),m.group(2)
        if url.startswith('&lt;') and url.endswith('&gt;'): url=url[4:-4]
        match=re.match(r'(?:\./)?([^/#]+\.md)(?:#(.*))?$',url,re.I)
        if match: url='#'+slug(match.group(1)[:-3]) + ('--'+slug(match.group(2)) if match.group(2) else '')
        if url.lower().startswith(('javascript:','data:')): return label
        return '<a href="'+html.escape(url,quote=True)+'">'+label+'</a>'
    s=re.sub(r'\[([^]]+)\]\(([^)]+)\)',link,s)
    return re.sub(r'&lt;(https?://[^ &]+)&gt;', lambda m: '<a href="'+html.escape(m.group(1), quote=True)+'">'+m.group(1)+'</a>', s)
def render(text, prefix):
    lines=text.splitlines(); out=[]; i=0; seen={}
    while i<len(lines):
        line=lines[i]
        if not line.strip(): i+=1; continue
        if line.startswith('```'):
            lang=line[3:].strip(); i+=1; code=[]
            while i<len(lines) and not lines[i].startswith('```'): code.append(lines[i]); i+=1
            out.append('<pre><code>'+html.escape('\n'.join(code))+'</code></pre>'); i+=1; continue
        m=re.match(r'^(#{1,6})\s+(.+?)\s*#*$',line)
        if m:
            level=min(6,len(m.group(1))+1); title=m.group(2); base=prefix+'--'+slug(title); seen[base]=seen.get(base,0)+1
            ident=base+('-'+str(seen[base]) if seen[base]>1 else '')
            out.append(f'<h{level} id="{ident}">{inline(title)}</h{level}>'); i+=1; continue
        if re.match(r'^\s*[-*_]{3,}\s*$',line): out.append('<hr>'); i+=1; continue
        if line.startswith('|') and i+1<len(lines) and re.match(r'^\|?\s*:?-+',lines[i+1]):
            rows=[]
            while i<len(lines) and lines[i].startswith('|'): rows.append([c.strip() for c in lines[i].strip().strip('|').split('|')]); i+=1
            out.append('<div class="table-wrap"><table><thead><tr>'+''.join('<th scope="col">'+inline(c)+'</th>' for c in rows[0])+'</tr></thead><tbody>'+''.join('<tr>'+''.join('<td>'+inline(c)+'</td>' for c in row)+'</tr>' for row in rows[2:])+'</tbody></table></div>'); continue
        if re.match(r'^\s*([-*+] |\d+\. )',line):
            ordered=bool(re.match(r'^\s*\d+\. ',line)); tag='ol' if ordered else 'ul'; items=[]
            while i<len(lines) and re.match(r'^\s*([-*+] |\d+\. )',lines[i]):
                items.append(re.sub(r'^\s*([-*+] |\d+\. )','',lines[i])); i+=1
            out.append('<'+tag+'>'+''.join('<li>'+inline(x)+'</li>' for x in items)+'</'+tag+'>'); continue
        if line.startswith('>'):
            q=[]
            while i<len(lines) and lines[i].startswith('>'): q.append(lines[i][1:].strip()); i+=1
            out.append('<blockquote><p>'+inline(' '.join(q))+'</p></blockquote>'); continue
        para=[line]; i+=1
        while i<len(lines) and lines[i].strip() and not re.match(r'^(#{1,6}\s|```|\s*[-*+] |\s*\d+\. |\||>)',lines[i]): para.append(lines[i]); i+=1
        content=inline(' '.join(para)); out.append(content if content.startswith('<figure>') else '<p>'+content+'</p>')
    return '\n'.join(out)
css='''
:root{color-scheme:light;--ink:#211b30;--muted:#625c6e;--accent:#60418d;--line:#e5dfec;--paper:#fff;--wash:#f7f5fa}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);background:var(--wash);font:16px/1.7 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}a{color:#59338e;text-underline-offset:3px}a:focus-visible{outline:3px solid #a78bda;outline-offset:3px}.skip{position:absolute;left:-9999px}.skip:focus{left:1rem;top:1rem;background:white;z-index:5;padding:.5rem}.layout{display:grid;grid-template-columns:250px minmax(0,1fr);max-width:1500px;margin:auto}.sidebar{position:sticky;top:0;height:100vh;overflow:auto;padding:2.3rem 1.5rem;border-right:1px solid var(--line)}.brand{font-weight:750;font-size:1.12rem;letter-spacing:-.02em}.eyebrow{color:var(--accent);font-size:.75rem;text-transform:uppercase;letter-spacing:.12em;font-weight:700}.sidebar nav{display:grid;gap:.35rem;margin-top:1.8rem}.sidebar nav a{padding:.45rem .65rem;border-radius:7px;text-decoration:none;color:var(--muted)}.sidebar nav a:hover{background:#eee8f5;color:var(--ink)}main{min-width:0;padding:3.5rem clamp(1.5rem,5vw,5rem) 6rem}article{max-width:920px;margin:auto}.hero{border-bottom:1px solid var(--line);padding-bottom:2rem;margin-bottom:3rem}.hero h1{font-size:clamp(2.5rem,5vw,4rem);line-height:1.05;letter-spacing:-.045em;margin:.5rem 0}.hero p{color:var(--muted);margin:0}.document{padding:0 0 3.5rem;margin-bottom:3.5rem;border-bottom:1px solid var(--line);scroll-margin-top:1.5rem}h2,h3,h4,h5,h6{line-height:1.22;letter-spacing:-.025em;scroll-margin-top:1.5rem}h2{font-size:2rem;margin:0 0 1.3rem}h3{font-size:1.4rem;margin:2.5rem 0 .8rem}h4{font-size:1.12rem;margin:1.8rem 0 .6rem}p,ul,ol{margin:.8rem 0 1.1rem}li{margin:.28rem 0}code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.88em}p code,li code,td code{background:#eeeaf3;padding:.15em .3em;border-radius:4px}pre{overflow:auto;background:#251f31;color:#f7f3ff;padding:1.2rem;border-radius:10px;line-height:1.55}figure{margin:2rem 0;padding:1rem;background:white;border:1px solid var(--line);border-radius:14px}figure svg{display:block;width:100%;height:auto}figcaption{color:var(--muted);font-size:.85rem;margin:.7rem .4rem .1rem}.table-wrap{overflow:auto}table{border-collapse:collapse;width:100%;font-size:.92rem}th,td{text-align:left;vertical-align:top;padding:.65rem;border-bottom:1px solid var(--line)}th{background:#f0ecf5}blockquote{border-left:3px solid #9b7ac5;margin:1.5rem 0;padding:.1rem 1.2rem;color:var(--muted)}hr{border:0;border-top:1px solid var(--line);margin:2rem 0}@media(max-width:750px){.layout{display:block}.sidebar{position:static;height:auto;border-right:0;border-bottom:1px solid var(--line);padding:1.3rem}.sidebar nav{display:flex;flex-wrap:wrap;margin-top:.7rem;gap:.2rem}main{padding:2.5rem 1.25rem}.hero h1{font-size:2.5rem}}@media print{body{background:white;font-size:10pt}.layout{display:block}.sidebar,.skip{display:none}main{padding:0}article{max-width:none}.document{break-before:page;border:0;margin:0;padding:0}figure,pre,table{break-inside:avoid}a{color:inherit}h2,h3,h4{break-after:avoid}}
'''
sections=[]; nav=[]
for file in FILES:
    path=ROOT/file
    if not path.exists(): continue
    text=path.read_text(); heading=re.search(r'^#\s+(.+)$',text,re.M); title=heading.group(1) if heading else path.stem.replace('-',' ').title(); prefix=slug(path.stem)
    if heading: text=text[:heading.start()]+text[heading.end():]
    nav.append(f'<a href="#{prefix}">{html.escape(title)}</a>')
    sections.append(f'<section class="document" id="{prefix}"><h2>{html.escape(title)}</h2>{render(text,prefix)}</section>')
if not sections: raise SystemExit('No documentation files found.')
page='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>OK, Copy Documentation</title><style>'+css+'</style></head><body><a class="skip" href="#content">Skip to content</a><div class="layout"><aside class="sidebar"><div class="eyebrow">Documentation</div><div class="brand">OK, Copy</div><nav aria-label="Documentation sections">'+''.join(nav)+'</nav></aside><main id="content"><article><header class="hero"><div class="eyebrow">Verified Copying Tool</div><h1>OK, Copy</h1><p>Documentation and technical reference</p></header>'+''.join(sections)+'</article></main></div></body></html>'
(ROOT/'index.html').write_text(page)
print('Built', ROOT/'index.html')
