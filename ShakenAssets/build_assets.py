from pathlib import Path
import json, math, subprocess, shutil, hashlib, zipfile
from PIL import Image, ImageDraw, ImageFont
ROOT=Path(__file__).resolve().parent
PACK=ROOT/'ShakenAssets'
PACK.mkdir(exist_ok=True)
CAT=PACK/'Assets.xcassets'; CAT.mkdir(exist_ok=True)
(CAT/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}},indent=2))
SRC=PACK/'Sources'; SRC.mkdir(exist_ok=True)
TMP=ROOT/'render'; TMP.mkdir(exist_ok=True)
def svg(body,size=24,defs=''):
 return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}"><defs>{defs}</defs>{body}</svg>'
def export(src,dest,px=None,pdf=False):
 args=['inkscape',str(src),'--export-type='+('pdf' if pdf else 'png'),'--export-filename='+str(dest)]
 if px: args+=['--export-width='+str(px),'--export-height='+str(px)]
 subprocess.run(args,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
def write(path,text):
 path.parent.mkdir(parents=True,exist_ok=True); path.write_text(text)
# Optically centered S, made of two rounded gesture strokes. No fonts or raster tracing.
smark='<path d="M620 342 L449 388 C356 413 348 502 424 518"/><path d="M404 682 L575 636 C668 611 676 522 600 506"/>'
defs='''<linearGradient id="tile" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#394660"/><stop offset=".5" stop-color="#171e30"/><stop offset="1" stop-color="#303b56"/></linearGradient><radialGradient id="sheen" cx=".18" cy=".02" r="1"><stop stop-color="#c8d7ff" stop-opacity=".24"/><stop offset=".6" stop-color="#b4c8ff" stop-opacity="0"/></radialGradient><linearGradient id="mark" x1="0" y1="0" x2=".5" y2="1"><stop stop-color="#fff"/><stop offset="1" stop-color="#e5eaff"/></linearGradient><linearGradient id="accent"><stop stop-color="#a9b5ff"/><stop offset="1" stop-color="#8390f5"/></linearGradient>'''
appbody='''<rect x="100" y="100" width="824" height="824" rx="188" fill="url(#tile)"/><rect x="101" y="101" width="822" height="822" rx="187" fill="url(#sheen)" stroke="#c5d2ff" stroke-opacity=".26" stroke-width="2"/>'''+f'<g fill="none" stroke="url(#mark)" stroke-width="76" stroke-linecap="round">{smark}</g>'+'''<g stroke="url(#accent)" stroke-width="24" stroke-linecap="round"><path d="M653 292 l15 -36"/><path d="M701 324 l30 -26"/><path d="M724 371 h38"/></g>'''
appsvg=SRC/'AppIcon.svg';write(appsvg,svg(appbody,1024,defs))
master=TMP/'app.png';export(appsvg,master,1024)
app=Image.open(master).convert('RGBA')
appdir=PACK/'AppIcon';appdir.mkdir(exist_ok=True)
for size in [16,18,20,24,32,40,48,64,96,128,256,512,1024]:
 app.resize((size,size),Image.Resampling.LANCZOS).save(appdir/f'Shaken-{size}.png')
app.save(appdir/'Shaken.icns',format='ICNS')
iconset=appdir/'Shaken.iconset';iconset.mkdir(exist_ok=True)
asset=CAT/'AppIcon.appiconset';asset.mkdir(exist_ok=True)
items=[]
for base in [16,32,128,256,512]:
 for scale in [1,2]:
  name=f'icon_{base}x{base}'+('@2x' if scale==2 else '')+'.png'
  app.resize((base*scale,base*scale),Image.Resampling.LANCZOS).save(iconset/name)
  shutil.copy2(iconset/name,asset/name)
  items.append({'idiom':'mac','size':f'{base}x{base}','scale':f'{scale}x','filename':name})
write(asset/'Contents.json',json.dumps({'images':items,'info':{'author':'xcode','version':1}},indent=2))
# All glyphs share a 24pt grid and 1.7pt stroke. Template glyph has a simpler 18pt geometry.
glyphs={
'Convert':'<rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="8" cy="9" r="1.3"/><path d="m4 18 5-5 4 3 3-4 4 6"/>',
'Compress':'<path d="M4 4l6 6m0-5v5H5M20 4l-6 6m0-5v5h5M4 20l6-6m-5 0h5v5M20 20l-6-6m0 5v-5h5"/>',
'Metadata':'<path d="M12 3 4 6v5c0 5 4 8 8 10 4-2 8-5 8-10V6Z"/><path d="m9 12 2 2 4-4"/>',
'Preview':'<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
'CopyName':'<path d="M5 5h14M12 5v14m-4 0h8"/>',
'Downloads':'<circle cx="12" cy="12" r="9"/><path d="M12 6v11m-4-4 4 4 4-4"/>',
'Shelf':'<path d="m3 14 3-8h4m4 0h4l3 8v6H3Zm0 0h5l2 3h4l2-3h5M12 2v10m-3-3 3 3 3-3"/>',
'Stack':'<path d="m3 8 9-5 9 5-9 5Zm0 5 9 5 9-5M3 18l9 5 9-5" transform="translate(0 -1)"/>',
'Link':'<path d="m10 14 4-4m-6 6-1 1a4 4 0 0 1-6-6l5-5a4 4 0 0 1 6 0m0 12a4 4 0 0 0 6 0l5-5a4 4 0 0 0-6-6l-1 1" transform="translate(1 0) scale(.92)"/>',
'Close':'<path d="m6 6 12 12M18 6 6 18"/>',
'SwitchApp':'<rect x="3" y="3" width="13" height="13" rx="2.5"/><rect x="8" y="8" width="13" height="13" rx="2.5"/>',
'Mute':'<path d="M10 5 5 9H2v6h3l5 4V5Zm5 4 6 6m0-6-6 6"/>',
'Calendar':'<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M7 3v4m10-4v4M3 10h18m-14 4h2m4 0h2m-8 3h2m4 0h2"/>',
'Backup':'<rect x="2" y="4" width="20" height="16" rx="3"/><path d="m6 9 3 3-3 3m7 0h4"/>',
'Keyboard':'<rect x="2" y="5" width="20" height="14" rx="3"/><path d="M6 9h.1m3.9 0h.1m3.9 0h.1m3.9 0h.1M6 12h.1m3.9 0h.1m3.9 0h.1m3.9 0h.1M7 16h10"/>',
'ChevronRight':'<path d="m9 5 7 7-7 7"/>'}
for name,body in glyphs.items():
 source=SRC/'Glyphs'/f'{name}.svg';write(source,svg(f'<g fill="none" stroke="#000" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">{body}</g>'))
 dst=PACK/'Glyphs'/name;dst.mkdir(parents=True,exist_ok=True)
 export(source,dst/f'{name}.pdf',pdf=True)
 export(source,TMP/f'{name}.png',96)
 im=Image.open(TMP/f'{name}.png').convert('RGBA')
 aset=CAT/f'{name}.imageset';aset.mkdir(exist_ok=True)
 shutil.copy2(dst/f'{name}.pdf',aset/f'{name}.pdf')
 write(aset/'Contents.json',json.dumps({'images':[{'idiom':'universal','filename':f'{name}.pdf'}],'info':{'author':'xcode','version':1},'properties':{'preserves-vector-representation':True,'template-rendering-intent':'template'}},indent=2))
 for size in [16,20,24,32]:
  for scale in [1,2,3]:
   im.resize((size*scale,size*scale),Image.Resampling.LANCZOS).save(dst/f'{name}-{size}pt@{scale}x.png')
# Menu bar image fills an 18pt canvas with 1pt safe margins and a single-color alpha mask.
menubody='<g fill="none" stroke="#000" stroke-width="2.1" stroke-linecap="round"><path d="m10.5 4-5 1.4c-2.7.7-2.7 3.3-.2 3.5l4.2.3c2.5.2 2.5 2.8-.2 3.5L4.5 14"/><path d="m12.7 2.8.7-1.5M14.8 4.6l1.4-1M15.5 7h1.4"/></g>'
menusvg=SRC/'ShakenMenuBarTemplate.svg';write(menusvg,svg(menubody,18))
menudir=PACK/'MenuBar';menudir.mkdir(exist_ok=True)
export(menusvg,menudir/'ShakenMenuBarTemplate.pdf',pdf=True)
export(menusvg,TMP/'menu.png',108)
mi=Image.open(TMP/'menu.png').convert('RGBA')
for size in [16,18,20,22,24,32]:
 for scale in [1,2,3]:
  mi.resize((size*scale,size*scale),Image.Resampling.LANCZOS).save(menudir/f'ShakenMenuBarTemplate-{size}pt@{scale}x.png')
mset=CAT/'ShakenMenuBarTemplate.imageset';mset.mkdir(exist_ok=True)
shutil.copy2(menudir/'ShakenMenuBarTemplate.pdf',mset/'ShakenMenuBarTemplate.pdf')
write(mset/'Contents.json',json.dumps({'images':[{'idiom':'mac','filename':'ShakenMenuBarTemplate.pdf'}],'info':{'author':'xcode','version':1},'properties':{'preserves-vector-representation':True,'template-rendering-intent':'template'}},indent=2))
# Independent wheel segments: canonical 420x420 canvas; keep labels and glyphs separate at runtime.
def pt(r,a):
 return (210+r*math.cos(math.radians(a)),210+r*math.sin(math.radians(a)))
def wedge(a):
 a1,a2=a-28.8,a+28.8
 p1,p2,p3,p4=pt(202,a1),pt(202,a2),pt(72,a2),pt(72,a1)
 return f'M{p1[0]:.4f},{p1[1]:.4f} A202,202 0 0 1 {p2[0]:.4f},{p2[1]:.4f} L{p3[0]:.4f},{p3[1]:.4f} A72,72 0 0 0 {p4[0]:.4f},{p4[1]:.4f}Z'
wheel=PACK/'Wheel';wheel.mkdir(exist_ok=True)
for theme,fill,stroke in [('Dark','#20283d','#c5d2ff'),('Light','#f5f7ff','#67728e')]:
 for selected in [False,True]:
  parts=[]
  for i,a in enumerate([-90,-30,30,90,150,210]):
   body=f'<path d="{wedge(a)}" fill="'+('#7d89ed' if selected else fill)+f'" fill-opacity="{1 if selected else .94}" stroke="{stroke}" stroke-opacity=".22" stroke-width="1" stroke-linejoin="round"/>'
   path=wheel/theme/(f'Slot-{i+1}'+('-Selected.svg' if selected else '.svg'));write(path,svg(body,420))
   parts.append(body)
  if not selected:
   parts.append(f'<circle cx="210" cy="210" r="67" fill="{fill}" fill-opacity=".94" stroke="{stroke}" stroke-opacity=".22"/>')
   write(wheel/theme/'WheelBackground.svg',svg(''.join(parts),420))
 for kind,body,size in [('Center',f'<circle cx="72" cy="72" r="67" fill="{fill}" fill-opacity=".94" stroke="{stroke}" stroke-opacity=".22"/>',144)]:
  write(wheel/theme/f'{kind}.svg',svg(body,size))
 write(wheel/theme/'Shelf.svg',f'<svg xmlns="http://www.w3.org/2000/svg" width="460" height="76" viewBox="0 0 460 76"><rect x="1" y="1" width="458" height="74" rx="18" fill="{fill}" fill-opacity=".94" stroke="{stroke}" stroke-opacity=".22"/></svg>')
# Preview of the actual shipped vectors, not the earlier generated concept.
font='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
F=lambda s:ImageFont.truetype(font,s)
canvas=Image.new('RGB',(1600,1080),'#101625');d=ImageDraw.Draw(canvas)
d.text((70,50),'shaken / production assets',font=F(40),fill='#f4f5ff')
d.text((70,108),'App icon · menu bar template · radial action glyphs',font=F(21),fill='#a4afca')
canvas.paste(app.resize((350,350)),(80,200),app.resize((350,350)))
d.text((110,550),'16  /  32  /  64  /  128 px',font=F(18),fill='#a4afca')
x=120
for s in [16,32,64,128]:
 im=app.resize((s,s));canvas.paste(im,(x,650-s//2),im);x+=s+22
for x,bg,fg in [(90,'#edf0f7','#121826'),(270,'#222b3f','#ffffff')]:
 d.rounded_rectangle((x,730,x+155,786),radius=12,fill=bg)
 ico=mi.resize((36,36));colored=Image.new('RGBA',ico.size,fg);colored.putalpha(ico.getchannel('A'));canvas.paste(colored,(x+60,740),colored)
d.text((90,805),'Template / light & dark',font=F(18),fill='#a4afca')
export(wheel/'Dark'/'WheelBackground.svg',TMP/'wheel.png',760)
wi=Image.open(TMP/'wheel.png').convert('RGBA');canvas.paste(wi,(700,155),wi)
sel=wheel/'Dark'/'Slot-2-Selected.svg';export(sel,TMP/'selected.png',760)
si=Image.open(TMP/'selected.png').convert('RGBA');canvas.paste(si,(700,155),si)
labels=['Convert','Compress','Metadata','Preview','Copy name','Downloads']
for i,(name,a) in enumerate(zip(['Convert','Compress','Metadata','Preview','CopyName','Downloads'],[-90,-30,30,90,150,210])):
 x=1080+math.cos(math.radians(a))*252;y=535+math.sin(math.radians(a))*252
 ico=Image.open(TMP/f'{name}.png').resize((42,42));co=Image.new('RGBA',ico.size,'white');co.putalpha(ico.getchannel('A'));canvas.paste(co,(int(x-21),int(y-36)),co)
 d.text((x,y+22),labels[i],font=F(21),fill='white',anchor='mm')
ico=Image.open(TMP/'Stack.png').resize((40,40));co=Image.new('RGBA',ico.size,'white');co.putalpha(ico.getchannel('A'));canvas.paste(co,(1060,493),co)
d.text((1080,554),'2 images',font=F(24),fill='white',anchor='mm');d.text((1080,584),'Drop to shelf',font=F(16),fill='#a4afca',anchor='mm')
d.rounded_rectangle((695,945,1465,1025),radius=20,fill='#20283d',outline='#46516c')
d.text((720,972),'Shelf     3 items',font=F(22),fill='white');d.text((950,975),'Cover.png     Notes.pdf     Link',font=F(19),fill='#cbd3e6')
canvas.save(PACK/'Preview.png')
# Structural validation.
for f in CAT.rglob('Contents.json'):
 c=json.loads(f.read_text())
 for item in c.get('images',[]):
  if 'filename' in item: assert (f.parent/item['filename']).is_file(),f
for f in PACK.rglob('*.png'):
 im=Image.open(f);im.verify()
assert Image.open(appdir/'Shaken.icns').size==(1024,1024)
print('Generated',len(list(PACK.rglob('*'))),'entries')
