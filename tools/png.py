"""Minimal PNG read/write (8-bit RGB/RGBA, no interlace) — no PIL in this container."""
import zlib, struct, sys

def read(path):
    d = open(path,'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat, pal, trns = 8, b'', None, None
    w=h=bd=ct=0
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos+4])[0]; typ = d[pos+4:pos+8]
        data = d[pos+8:pos+8+ln]; pos += 12+ln
        if typ==b'IHDR':
            w,h,bd,ct,_,_,il = struct.unpack('>IIBBBBB', data)
            assert bd==8 and il==0, (bd,il)
        elif typ==b'IDAT': idat += data
        elif typ==b'PLTE': pal = data
        elif typ==b'tRNS': trns = data
        elif typ==b'IEND': break
    raw = zlib.decompress(idat)
    nch = {0:1,2:3,3:1,4:2,6:4}[ct]
    stride = w*nch
    out = bytearray(h*stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        if f==1:
            for i in range(nch, stride): line[i]=(line[i]+line[i-nch])&255
        elif f==2:
            for i in range(stride): line[i]=(line[i]+prev[i])&255
        elif f==3:
            for i in range(stride):
                a = line[i-nch] if i>=nch else 0
                line[i]=(line[i]+((a+prev[i])>>1))&255
        elif f==4:
            for i in range(stride):
                a = line[i-nch] if i>=nch else 0
                c = prev[i-nch] if i>=nch else 0
                b = prev[i]
                pa,pb,pc = abs(b-c),abs(a-c),abs(a+b-2*c)
                pr = a if (pa<=pb and pa<=pc) else (b if pb<=pc else c)
                line[i]=(line[i]+pr)&255
        out[y*stride:(y+1)*stride]=line
        prev = line
    # expand to RGBA
    px = bytearray(w*h*4)
    for i in range(w*h):
        if ct==6: px[i*4:i*4+4]=out[i*4:i*4+4]
        elif ct==2: px[i*4:i*4+3]=out[i*3:i*3+3]; px[i*4+3]=255
        elif ct==0: v=out[i]; px[i*4:i*4+3]=bytes([v,v,v]); px[i*4+3]=255
        elif ct==4: v=out[i*2]; px[i*4:i*4+3]=bytes([v,v,v]); px[i*4+3]=out[i*2+1]
        elif ct==3:
            idx=out[i]; px[i*4:i*4+3]=pal[idx*3:idx*3+3]
            px[i*4+3]= trns[idx] if (trns and idx<len(trns)) else 255
    return w,h,px

def write(path,w,h,px):
    raw=bytearray()
    for y in range(h):
        raw.append(0); raw += px[y*w*4:(y+1)*w*4]
    def chunk(t,d):
        c=struct.pack('>I',len(d))+t+d
        return c+struct.pack('>I', zlib.crc32(t+d)&0xffffffff)
    open(path,'wb').write(b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB',w,h,8,6,0,0,0))
        + chunk(b'IDAT', zlib.compress(bytes(raw),6)) + chunk(b'IEND', b''))

def crop(px,w,h,x0,y0,cw,ch):
    o=bytearray(cw*ch*4)
    for y in range(ch):
        s=((y0+y)*w+x0)*4
        o[y*cw*4:(y+1)*cw*4]=px[s:s+cw*4]
    return o

if __name__=='__main__':
    cmd=sys.argv[1]
    if cmd=='crop':
        src,dst,x0,y0,cw,ch = sys.argv[2],sys.argv[3],*map(int,sys.argv[4:8])
        w,h,px=read(src); write(dst,cw,ch,crop(px,w,h,x0,y0,cw,ch))
    elif cmd=='px':
        w,h,px=read(sys.argv[2])
        for a in sys.argv[3:]:
            x,y=map(int,a.split(',')); i=(y*w+x)*4
            print(a, tuple(px[i:i+4]))
    elif cmd=='info':
        w,h,px=read(sys.argv[2]); print(w,h)
