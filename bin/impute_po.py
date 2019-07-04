#!/well/kong/users/wiw765/anaconda2/bin/python
import numpy as np
import numpy.ma as ma
from pysnptools.snpreader import Bed, Pheno
import h5py, argparse, code

# def impute(g,pg,f):
#     if pg==2:
#         if g>0:
#             return (g-1+f)
#         else:
#             return np.nan
#     elif pg==1:
#         return 0.5*g+f
#     elif pg==0:
#         if g<2:
#             return g+f
#         else:
#             return np.nan

def impute(g,pg,f):
    gcounts = np.array([np.sum(g==x) for x in range(0,3)])
    if pg == 2:
        if gcounts[0]>0:
            return np.nan
        elif gcounts[1] == 0:
            return (1+f*(2**g.shape[0]-1))/(1+f*(2**(g.shape[0]-1)-1))
        elif gcounts[1] == g.shape[0]:
            return f/(2**(g.shape[0]-1)-f*(2**(g.shape[0]-1)-1))
        else:
            return 1
    if pg == 1:
        if gcounts[0] == 0 and gcounts[2]>0:
            return (1 + f * (2 ** gcounts[2] - 1)) / (1 + f * (2 ** (gcounts[2] - 1) - 1))
        if gcounts[0]>0 and gcounts[2]>0:
            return 1
        if gcounts[2]==0 and gcounts[0]>0:
            e = g.shape[0]-gcounts[1]-1
            return f/(2**e-f*(2**e-1))
        if gcounts[1] == g.shape[0]:
            return 2*f
    if pg == 0:
        if gcounts[2]>0:
            return np.nan
        elif gcounts[1] == g.shape[0]:
            return (1+f*(2**g.shape[0]-1))/(1+f*(2**(g.shape[0]-1)-1))
        elif gcounts[1] == 0:
            return f/(2**(g.shape[0]-1)-f*(2**(g.shape[0]-1)-1))
        else:
            return 1

def simulate_sib(father,mother):
    return np.random.choice(father,1)+np.random.choice(mother,1)

def simulate_fam(n,f):
    father = np.random.binomial(1,f,2)
    mother = np.random.binomial(1,f,2)
    return [np.sum(father),np.sum(mother),np.array([simulate_sib(father,mother) for x in range(0,n)]).reshape((n))]

def test_impute(n,f):
    fam = simulate_fam(n,f)
    imputed = impute(fam[2],fam[0],f)
    return np.array([imputed,fam[1]])

# nrep = 10**6
# imputed = np.zeros((nrep,2))
# for i in xrange(0,nrep):
#  imputed[i,:] = test_impute(2,0.5)
#
# imps = np.unique(imputed[:, 0])
# imp_means = np.zeros((imps.shape[0]))
# for i in range(0, imps.shape[0]):
#     imp_means[i] = np.mean(imputed[imputed[:, 0] == imps[i], 1])
#
# imps - imp_means

######### Command line arguments #########
if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('gts',type=str,help='Path to bed file with parent and offspring genotypes')
    parser.add_argument('ped',type=str,help='Path to pedigree file with parent offspring pairs')
    parser.add_argument('out',type=str,help='Prefix of HDF5 output file with imputed parental genotypes')
    args=parser.parse_args()

    ####################### Read in data #########################
### Read pedigree file ###
    ### Load pedigree
    ped = np.loadtxt(args.ped, dtype='S20', skiprows=1)
    #ped = np.loadtxt('relatedness/one_parent_genotyped.ped', dtype='S20', skiprows=1)

### Read genotypes ###
    #### Load genotypes
    gts_f = Bed(args.gts)
    #gts_f = Bed('genotypes/chr_22.bed')
    gts_ids = gts_f.iid
    # Build dict
    id_dict = {}
    for i in xrange(0, gts_ids.shape[0]):
        id_dict[gts_ids[i, 1]] = i

    # Find indices
    indices = np.zeros((ped.shape),dtype = int)
    indices[:] = -1
    ped_new = ped
    for i in xrange(0, ped.shape[0]):
        if ped[i,0] in id_dict and ped[i,1] in id_dict:
            indices[i,:] = np.array([id_dict[x] for x in ped[i,:]])
        else:
            print('Missing data for '+ped[i,0])
            ped_new = np.delete(ped_new,i,0)

    ped = ped_new
    indices = indices[indices[:,0]>0,:]
    index_vector = np.sort(np.unique(indices.reshape(indices.shape[0]*indices.shape[1])))

    # Read genotypes
    gts = gts_f[index_vector, :].read().val
    pos = gts_f.pos[:, 2]
    sid = gts_f.sid
    gts = ma.array(gts,mask=np.isnan(gts),dtype=int)

    # rebuild ID dictionary
    gts_ids = gts_ids[index_vector]
    # Build dict
    id_dict = {}
    for i in xrange(0, gts_ids.shape[0]):
        id_dict[gts_ids[i, 1]] = i

    # Output array
    imputed_par_gts = np.zeros((ped.shape[0], gts.shape[1]), dtype=np.float32)
    imputed_par_gts[:] = np.nan

    freqs = ma.mean(gts,axis=0)/2.0

    for i in range(0,ped.shape[0]):
        cgts = gts[id_dict[ped[i,0]],:]
        pgts = gts[id_dict[ped[i,1]],:]
        for j in range(0,gts.shape[1]):
            if np.sum(np.array([cgts.mask[j],pgts.mask[j]]))==0:
                imputed_par_gts[i,j] = impute(cgts[j],pgts[j],freqs[j])

    par_gt_f = h5py.File(args.out+'.hdf5','w')
    par_gt_f.create_dataset('imputed_par_gts',imputed_par_gts.shape,dtype = 'f',chunks = True, compression = 'gzip', compression_opts=9)
    par_gt_f['imputed_par_gts'][:] = imputed_par_gts
    par_gt_f['ped'] = ped
    par_gt_f['pos'] = pos
    par_gt_f['sid'] = sid
    par_gt_f.close()
