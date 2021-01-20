import h5py, argparse
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('estimated_effects',type=str,help='path to file with estimated effects')
parser.add_argument('true_effects',type=str,help='path to file with true effects')
args=parser.parse_args()

f = h5py.File(args.estimated_effects,'r')

ests = np.array(f['estimate'])

b = np.loadtxt(args.true_effects)

pop = ests.dot(np.array([1,0.5,0.5]).reshape((3,1)))

breg = np.zeros((4,2))

for i in range(3):
    breg[i,1] = 1/np.var(b[:,i])
    breg[i,0] = np.cov(b[:,i],ests[:,i])[0,1]*breg[i,1]
    sigma2 = np.var(ests[:,i]-breg[i,0]*b[:,i])
    breg[i,1] = np.sqrt(sigma2*breg[i,1]/np.float(b.shape[0]))

breg[3,0] = np.cov(pop[:,0],b[:,0])[0,1]/np.var(b[:,0])
sigma2 = np.var(pop[:,0]-breg[3,0]*b[:,0])
breg[3,1] = np.sqrt(sigma2/(b.shape[0]*np.var(b[:,0])))

print('Bias for direct genetic effects: '+str(round(breg[0,0]-1,4))+'; S.E. '+str(round(breg[0,1],4)))
print('Bias for paternal  effects: '+str(round(breg[1,0]-1,4))+'; S.E. '+str(round(breg[1,1],4)))
print('Bias for maternal effects: '+str(round(breg[2,0]-1,4))+'; S.E. '+str(round(breg[2,1],4)))
print('Bias for population effects as estimates of direct effects: '+str(round(breg[3,0]-1,4))+'; S.E. '+str(round(breg[3,1],4)))
