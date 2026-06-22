#!/usr/bin/env python3
# Math proof for the spectral cube: (1) summing the 128 per-channel images exactly reconstructs the
# broadband image (lossless split), (2) the planet brightness is linear in channel (Apl^2 ~ 2c/255),
# (3) ch0 has no planet (only the star + PSF sidelobe floor). Mirrors bf_rx_host_corr.cu's decomposition.
import numpy as np
N=16; NANT=256; NCH=128; Astar=2.0; l=0.25; m=0.15; BF_NCH=256
qy,qx=np.meshgrid(np.arange(N),np.arange(N),indexing='ij'); qy=qy.ravel(); qx=qx.ravel()
phi=np.pi*(qx*l+qy*m)                                    # planet phase (same for all channels)
def chan_X(c):
    Apl=Astar*np.sqrt(2.0*c/(BF_NCH-1))
    return (Astar+Apl*np.cos(phi))+1j*(Apl*np.sin(phi))   # X[256] for channel c
def image(V,Ng=32):
    G=np.zeros((Ng,Ng),complex)
    for a in range(256):
        for b in range(256): G[(qy[a]-qy[b])%Ng,(qx[a]-qx[b])%Ng]+=V[a,b]
    return np.fft.fftshift(np.real(np.fft.fft2(G)))
def planet_pct(I):
    c=I.shape[0]//2; star=I[c,c]; M=I.copy()
    for dy in range(-2,3):
        for dx in range(-2,3): M[(c+dy)%I.shape[0],(c+dx)%I.shape[1]]=-1e30
    return 100*M.max()/star
Vbb=np.zeros((256,256),complex); Isum=np.zeros((32,32)); pct={}
for c in range(NCH):
    X=chan_X(c); Vc=np.outer(X,X.conj()); Vbb+=Vc
    Ic=image(Vc); Isum+=Ic
    if c in (0,16,32,64,96,127): pct[c]=planet_pct(Ic)
Ibb=image(Vbb)
print("SUM-of-channels == broadband image?  max|Isum-Ibb|/max(Ibb) =", np.max(np.abs(Isum-Ibb))/np.max(np.abs(Ibb)))
print("broadband planet =", f"{planet_pct(Ibb):.1f}% of star")
print("\nch   planet%   ratio-to-ch127   (expect c/127; ch0 = PSF sidelobe floor, not a planet)")
for c in sorted(pct):
    print(f"{c:4d}   {pct[c]:7.2f}%    {pct[c]/pct[127]:.3f}   (c/127={c/127:.3f})")
