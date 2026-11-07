#!/usr/bin/env python3
"""Regenerate the three vector block diagrams (requires svgwrite)."""
from pathlib import Path
import svgwrite
SVGDIR=Path(__file__).resolve().parent.parent/'assets'/'vector'
SVGDIR.mkdir(parents=True,exist_ok=True)
BG='#ffffff'; INK='#17263b'; MUTED='#4c5f77'; BLUE='#1658b9'; DARKBLUE='#0b438f'; TEAL='#087f81'; PURPLE='#6553a3'; BORDER='#a8bdd1'; LIGHT='#edf4fc'; PAPER='#f8fbff'

def make_svg(w,h):
 d=svgwrite.Drawing(size=(f'{w}px',f'{h}px'),viewBox=f'0 0 {w} {h}',profile='full')
 d.add(d.rect(insert=(0,0),size=(w,h),fill=BG))
 defs=d.defs
 for name,color in [('blue',BLUE),('teal',TEAL),('purple',PURPLE),('ink',INK)]:
  mk=d.marker(id=f'arrow-{name}',insert=(8,4),size=(9,8),orient='auto')
  mk.add(d.path(d='M 0 0 L 8 4 L 0 8 z',fill=color))
  defs.add(mk)
 return d

def text(d,x,y,s,size=18,weight=400,fill=INK,anchor='start',font='DejaVu Sans, Arial, sans-serif'):
 t=d.text(s,insert=(x,y),fill=fill,font_size=size,font_weight=int(round(weight/100)*100),text_anchor=anchor,font_family=font)
 d.add(t)
 return t

def multiline(d,x,y,lines,size=18,dy=25,weight=500,fill=INK,anchor='middle'):
 for i,l in enumerate(lines): text(d,x,y+i*dy,l,size,weight,fill,anchor)

def box(d,x,y,w,h,title,sub=None,fill=LIGHT,accent=BLUE,size=19):
 d.add(d.rect(insert=(x,y),size=(w,h),rx=10,ry=10,fill=fill,stroke=accent,stroke_width=2.5))
 if isinstance(title,str):title=[title]
 if sub:
  start=y+36
  multiline(d,x+w/2,start,title,size,26,700)
  multiline(d,x+w/2,start+len(title)*26+4,sub,15,22,400,MUTED)
 else:
  htext=(len(title)-1)*25
  multiline(d,x+w/2,y+h/2-htext/2+6,title,size,25,700)

def poly(d,pts,color=BLUE,width=3,arrow='end',dash=None):
 kwargs={'points':pts,'fill':'none','stroke':color,'stroke_width':width,'stroke_linejoin':'round','stroke_linecap':'round'}
 if dash: kwargs['stroke_dasharray']=dash
 if arrow in ('end','both'):kwargs['marker_end']=f'url(#arrow-{ {BLUE:"blue",TEAL:"teal",PURPLE:"purple",INK:"ink"}[color]})'
 if arrow in ('start','both'):kwargs['marker_start']=f'url(#arrow-{ {BLUE:"blue",TEAL:"teal",PURPLE:"purple",INK:"ink"}[color]})'
 d.add(d.polyline(**kwargs))


def overview(edition):
 """Signal names are from corresponding Section 4/5 pin assignments.
 Architecture and connections are simplified from Section 3 and Figure 1.
 """
 early=(edition=='tech')
 d=make_svg(1700,850)
 text(d,48,48,'AMY 1 — functional blocks and system-bus connections',29,700)
 text(d,50,79,('Earlier Technical Manual pinout' if early else 'Rev. B specification pinout')+' • functional redrawing, not electrical timing',16,400,MUTED)
 # Group annotations / non-circuit boundaries
 d.add(d.rect(insert=(18,110),size=(264,515),rx=14,ry=14,fill='#f5f9ff',stroke=BORDER,stroke_width=1.5))
 text(d,150,145,'External µP bus',20,700,anchor='middle')
 text(d,150,170,'Bus-compatible interface',14,400,MUTED,anchor='middle')
 # clear signal name cards
 for y,key,val in [
  (215,'Bidirectional data','DB7–DB0'),
  (302,'Address and strobes','A1, A0, ALE'),
  (382,'Read/write select','RD, WR, CS'),
  (460,'System timing','CLK, RESET'),
  (536,'Status output','INT/RDY')]:
  text(d,42,y,key,14,700,MUTED)
  text(d,42,y+30,val,19,650,INK)
 # processor box
 box(d,325,270,250,216,['Processor interface','and interrupt logic'],['command and data staging'],fill='#f0f5ff')
 # signal arrows at bus boundary (indicate direction)
 poly(d,[(260,244),(303,244),(303,324),(325,324)],BLUE,3,'both')
 poly(d,[(260,392),(325,392)],TEAL,3,'end')
 poly(d,[(325,455),(300,455),(300,575),(260,575)],PURPLE,3,'end')
 text(d,293,236,'8-bit bus',14,550,BLUE,anchor='middle')
 # Internal distribution path, not intended as literal bus wire grouping
 d.add(d.rect(insert=(655,245),size=(178,265),rx=11,ry=11,fill='#f0f7fa',stroke=TEAL,stroke_width=2.5))
 multiline(d,744,315,['Internal','control/data','paths'],19,27,700,TEAL)
 multiline(d,744,418,['to time-shared','AMY blocks'],14,21,400,MUTED)
 poly(d,[(575,382),(655,382)],BLUE,3,'both')
 text(d,616,372,'internal bus',13,500,MUTED,anchor='middle')
 # Major blocks preserve original ordering (noise, freq/amp, phase, SIN, accumulator)
 box(d,895,119,230,97,['Noise generator'],['Noise RAM • two channels'],fill='#f4fafa',accent=TEAL,size=20)
 box(d,1180,119,300,105,['Frequency & amplitude','generation'],fill=LIGHT,size=20)
 box(d,1180,274,300,91,['Phase generation'],fill=LIGHT,size=20)
 box(d,1180,415,300,91,['Sine argument','formation'],fill=LIGHT,size=20)
 box(d,1180,571,300,113,['Sample formation &','accumulator'],fill=LIGHT,size=20)
 # noise / freq and amplitude connection, and generation chain
 poly(d,[(1125,171),(1180,171)],TEAL,3,'both')
 poly(d,[(1330,224),(1330,274)],BLUE,3,'end')
 poly(d,[(1330,365),(1330,415)],BLUE,3,'end')
 poly(d,[(1330,506),(1330,571)],BLUE,3,'end')
 # side amplitude bypass into sine / sample pathway as in original drawing
 poly(d,[(1480,204),(1530,204),(1530,446),(1480,446)],BLUE,2.8,'end')
 text(d,1512,398,'amp.',13,500,BLUE,anchor='middle')
 # control/data distribution fanouts follow shared trunk; not literal pin traces
 poly(d,[(833,305),(862,305),(862,196),(1180,196)],TEAL,2.7,'end')
 poly(d,[(833,350),(1180,350)],TEAL,2.7,'end')
 poly(d,[(833,448),(1180,448)],TEAL,2.7,'end')
 poly(d,[(833,494),(867,494),(867,650),(1180,650)],TEAL,2.7,'end')
 # 16bit output and control
 poly(d,[(1480,607),(1635,607)],BLUE,3.1,'end')
 text(d,1572,591,'16-bit output',15,600,BLUE,anchor='middle')
 text(d,1572,636,'SAMP[15:0]',16,700,INK,anchor='middle')
 poly(d,[(1480,677),(1635,677)],PURPLE,2.5,'end')
 text(d,1562,702,('OUTSTB/T1' if not early else 'OUTSTB'),14,600,PURPLE,anchor='middle')
 # input OE from right end (not enough space for text on right)
 poly(d,[(1636,546),(1500,546),(1500,588),(1480,588)],PURPLE,2.5,'end')
 text(d,1603,534,'OE (input)',14,700,PURPLE,anchor='middle')
 # V0 notification output
 poly(d,[(1234,684),(1234,741)],PURPLE,2.5,'end')
 text(d,1234,768,('V0/T0' if not early else 'V0')+' (voice zero)',14,600,PURPLE,anchor='middle')
 # label frequency path and interpretation note
 text(d,1353,259,'frequency',13,500,BLUE)
 text(d,48,804,'Connections combine Atari’s overview block drawing and pin/interface descriptions; signal timing and bus cycles are specified separately.',14,400,MUTED)
 return d

def internal():
 d=make_svg(1530,690)
 text(d,35,48,'AMY 1 — simplified internal architecture (Figure 1)',27,700)
 text(d,35,78,'Functional blocks and internal transfers redrawn from the original Atari figure',16,400,MUTED)
 box(d,35,250,165,90,['µP', 'interface'],fill='#f5f8fe',size=19)
 box(d,255,240,250,110,['System Bus','Interface'],fill=LIGHT,size=22)
 box(d,565,240,245,110,['Envelope','Generators'],fill=LIGHT,size=22)
 box(d,565,95,245,85,['Noise Generator'],fill='#f4fafa',accent=TEAL,size=21)
 box(d,870,240,230,110,['Exponential','ROM'],fill=LIGHT,size=22)
 box(d,870,417,260,112,['Phase Generation','& Argument','Formation'],fill=LIGHT,size=21)
 box(d,1180,428,202,96,['SIN ROM'],fill=LIGHT,size=21)
 box(d,1165,555,236,100,['Output','Accumulator'],fill=LIGHT,size=21)
 box(d,274,440,211,91,['Sequencer'],fill=LIGHT,size=21)
 # main chain
 poly(d,[(200,295),(255,295)],BLUE,3.2,'both')
 poly(d,[(505,295),(565,295)],BLUE,3.2,'both')
 poly(d,[(810,295),(870,295)],BLUE,3.2,'end')
 poly(d,[(686,180),(686,240)],TEAL,3,'end')
 poly(d,[(985,350),(985,417)],BLUE,3,'end')
 text(d,969,387,'F / DISP',14,600,BLUE,anchor='end')
 poly(d,[(1130,474),(1180,474)],BLUE,3,'end')
 poly(d,[(1280,524),(1280,555)],BLUE,3,'end')
 poly(d,[(1401,605),(1505,605)],BLUE,3,'end')
 text(d,1455,586,'16-bit digital output',14,600,BLUE,anchor='middle')
 # sequencer / control bus
 poly(d,[(380,350),(380,440)],PURPLE,2.9,'end')
 poly(d,[(380,531),(380,593)],PURPLE,2.9,'end')
 text(d,380,625,'Control bus',18,600,PURPLE,anchor='middle')
 text(d,35,667,'Original figure shows eight functional blocks; boxes and arrows denote functional information flow, not physical wiring.',14,400,MUTED)
 return d

for fn,d in [('overview_rev_b.svg',overview('spec')),('overview_technical_manual.svg',overview('tech')),('internal_architecture.svg',internal())]:
 d.saveas(SVGDIR/fn)

