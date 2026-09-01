"""Per-channel histogram summary of a rectangle, for eyeballing tone against a reference."""
import sys
sys.path.insert(0, __file__.rsplit('/',1)[0])
import png

def stats(path, x0, y0, x1, y1):
    w,h,pxs = png.read(path)
    vals=[[],[],[]]
    for y in range(y0,min(y1,h)):
        for x in range(x0,min(x1,w)):
            i=(y*w+x)*4
            for c in range(3): vals[c].append(pxs[i+c])
    out=[]
    for c in range(3):
        v=sorted(vals[c]); n=len(v)
        out.append((v[n//20], v[n//2], v[int(n*0.95)], round(sum(v)/n,1), round(100.0*sum(1 for t in v if t>=254)/n,1)))
    return out

if __name__=='__main__':
    p=sys.argv[1]; x0,y0,x1,y1=map(int,sys.argv[2:6])
    r=stats(p,x0,y0,x1,y1)
    print(p, "[%d,%d..%d,%d]"%(x0,y0,x1,y1))
    for name,s in zip("RGB", r):
        print("  %s p5=%3d med=%3d p95=%3d mean=%6.1f clipped=%4.1f%%" % (name,*s))
