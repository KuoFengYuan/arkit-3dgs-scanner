#!/usr/bin/env python3
"""Compare local planar-patch thickness at fixed baseline locations, not absolute accuracy.
No assumption that a detected patch is a wall; real layers/furniture can contribute thickness.
"""
import argparse,json
from pathlib import Path
import numpy as np
from scipy.spatial import cKDTree
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from ply_io import read_ply

def compare(before,after,out):
    a,_=read_ply(before); b,_=read_ply(after)
    ta,tb=cKDTree(a),cKDTree(b)
    rng=np.random.default_rng(42)
    centers=a[rng.choice(len(a),min(3000,len(a)),replace=False)]
    rows=[]; missing=0
    for center in centers:
        ia=ta.query_ball_point(center,.20)
        if len(ia)<30: continue
        pa=a[ia]; values,vectors=np.linalg.eigh(np.cov(pa.T))
        # Require a two-dimensional local region; no thickness cutoff or semantic wall claim.
        if values[1]<.001 or values[0]>.35*values[1]: continue
        ib=tb.query_ball_point(center,.20)
        if len(ib)<15: missing+=1; continue
        normal=vectors[:,0]
        da=pa@normal; db=b[ib]@normal
        wa=np.diff(np.percentile(da,[10,90]))[0]; wb=np.diff(np.percentile(db,[10,90]))[0]
        rows.append([wa,wb,len(ia),len(ib),float(np.median(db)-np.median(da))])
    rows=np.asarray(rows)
    def cells(p): return set(map(tuple,np.floor(p/.1).astype(np.int32)))
    ca,cb=cells(a),cells(b)
    report={'before_points':len(a),'after_points':len(b),'matched_patches':len(rows),'missing_patches':missing,
        'patch_radius_m':.2,'baseline_10cm_cells':len(ca),'after_10cm_cells':len(cb),
        'baseline_cell_retention':len(ca&cb)/len(ca),
        'thickness_p10_p90_band_cm_before':(np.percentile(rows[:,0],[50,90])*100).tolist(),
        'thickness_p10_p90_band_cm_after':(np.percentile(rows[:,1],[50,90])*100).tolist(),
        'median_abs_patch_shift_cm':float(np.median(abs(rows[:,4]))*100),
        'fraction_patches_thinner':float(np.mean(rows[:,1]<rows[:,0])),
        'limitations':'Fixed local PCA patches; thickness includes real structures. No ground truth, not absolute accuracy.'}
    out.mkdir(parents=True,exist_ok=True)
    (out/'metrics.json').write_text(json.dumps(report,indent=2))
    np.save(out/'patch-metrics.npy',rows)
    fig,ax=plt.subplots(1,3,figsize=(15,5))
    for i,(p,label) in enumerate([(a,'Before'),(b,'After')]):
        q=p[rng.choice(len(p),min(90000,len(p)),replace=False)]
        ax[i].scatter(q[:,0],q[:,2],c=q[:,1],s=.15,cmap='viridis',rasterized=True)
        ax[i].set_aspect('equal');ax[i].set_title(f'{label}: {len(p):,} points');ax[i].set_xlabel('X (m)');ax[i].set_ylabel('Z (m)')
    ax[2].hist(rows[:,0]*100,bins=40,alpha=.5,label='Before');ax[2].hist(rows[:,1]*100,bins=40,alpha=.5,label='After')
    ax[2].set_xlabel('Local patch P10-P90 thickness (cm)');ax[2].legend();ax[2].set_title('Same baseline patches; not absolute accuracy')
    fig.tight_layout();fig.savefig(out/'comparison.png',dpi=180)
    print(json.dumps(report,indent=2))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('before',type=Path);p.add_argument('after',type=Path);p.add_argument('output',type=Path);a=p.parse_args();compare(a.before,a.after,a.output)
