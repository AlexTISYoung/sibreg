"""Contains functions in cython for doing the parent sum imputation from the sibs.

Functions
----------
    is_possible_child
    dict_to_cmap
    impute_snp_from_offsprings
    impute_snp_from_parent_offsprings
    get_IBD_type
    impute
"""
# distutils: language = c++
#!/well/kong/users/wiw765/anaconda2/bin/python
import numpy as np
import pandas as pd
import logging
from libcpp.map cimport map as cmap
from libcpp.string cimport string as cstring
from libcpp.pair cimport pair as cpair
cimport numpy as cnp
from libcpp.vector cimport vector
import cython
from libc.math cimport isnan
import h5py
from cython.parallel import prange
cimport openmp
from libc.stdio cimport printf
from libc.time cimport time, ctime, time_t
cdef float nan_float = np.nan

cdef extern from * nogil:
    r"""
    #include <omp.h>
    #include <stdio.h>  
    #include <string.h>
    static omp_lock_t cnt_lock;
    static int cnt = 0;
    void reset(){
        omp_init_lock(&cnt_lock);
        cnt = 0;
    }
    void destroy(){
        omp_destroy_lock(&cnt_lock);
    }   
    void report(int mod, char* chromosomes, int total){
        time_t now;
        char* text;
        omp_set_lock(&cnt_lock);
        cnt++;
        if(cnt%mod == 0){
            now = time(NULL);
            text = ctime(&now);
            text[strlen(text)-1] = 0;
            printf("%s INFO impute with chromosome %s: progress is %d \n", text, chromosomes, (100*cnt)/total);
        }
        omp_unset_lock(&cnt_lock);
    }
    """
    void reset()
    void destroy()
    void report(int mod, char* pre_message_info, int total)

cdef void get_IBD(int[:] hap1,
                  int[:] hap2,
                  int length,
                  int half_window,
                  double threshold,
                  int[:] agreement_count,
                  double[:] agreement_percentage,
                  int[:] agreement):
    """Inferes IBD status between two haplotypes. For the location i, it checks [i-half_window, i+half_window] size, if they are the same on more than threshold portiona of the locations, it's IBD.
    Agreement, agreement_count, agreement percentage will contain the inffered IBDs, number of similarities in the window and its percentage for all the locations respectively.
asdasd
    Args:
        hap1 : int[:]
            First haplotype

        hap2 : int[:]
            Second haplotype

        length : int
            Length of the haplotypes

        half_window : int
            For each location i, the IBD inference is restricted to [i-half_window, i+half_window] segment

        threshold : float
            We have an IBD segment if agreement_percentage is more than threshold

        agreement_count : int[:]
            For each location i, it's number of the time haplotypes agree with each other in the [i-half_window, i+half_window] window

        agreement_percentage : float[:]
            For each location i, it's the ratio of agreement between haplotypes in [i-half_window, i+half_window] window

        agreement : int[:]
            For each location i, it's the IBD status between haplotypes"""
    cdef int i
    cdef int first, last
    agreement_count[0] = 0
    last = min(half_window, length-1)
    for i in range(last+1):
        agreement_count[0] += (hap1[i] == hap2[i])
    agreement_percentage[0] = agreement_count[0]/<double>(last+1)

    for i in range(1, length):
        agreement_count[i] = agreement_count[i-1]
        last = i+half_window
        first = i-half_window-1
        if 0 <= first:
            agreement_count[i] = agreement_count[i-1]-(hap1[first] == hap2[first])
        if last < length:
            agreement_count[i] = agreement_count[i]+(hap1[last] == hap2[last])
        agreement_percentage[i] = agreement_count[i]/<double>(min(last+1, length) - max(0, first+1))
    
    for i in range(length):
        agreement[i] = (agreement_percentage[i]>threshold)
        if hap1[i] != hap2[i]:
            agreement[i] = 0


cdef int get_hap_index(int i, int j) nogil:
    """Maps an unordered pair of integers to a single integer. Mapping is unique and continous.
    Args:
        i : int
            
        j : int

    Returns:
        int"""
    if i > j:
        return i*(i-1)/2+j
    if j > i:
        return j*(j-1)/2+i
    0/0

cdef char is_possible_child(int child, int parent) nogil:
    """Checks whether a person with child genotype can be an offspring of someone with the parent genotype.
    """
    if (parent == 2) and (child > 0):
        return True

    if parent == 1:
        return True
    
    if (parent == 0) and (child < 2):
        return True

    return False

cdef cmap[cpair[cstring, cstring], vector[int]] dict_to_cmap(dict the_dict):
    """ Converts a (str,str)->list[int] to cmap[cpair[cstring, cstring], vector[int]]

    Args:
        the_dict : (str,str)->list[int]

    Returns:
        cmap[cpair[cstring, cstring], vector[int]]
    """
    cdef cpair[cstring,cstring] map_key
    cdef vector[int] map_val
    cdef cpair[cpair[cstring,cstring], vector[int]] map_element
    cdef cmap[cpair[cstring, cstring], vector[int]] c_dict
    for key,val in the_dict.items():
        map_key.first = key[0].encode('ASCII')
        map_key.second = key[1].encode('ASCII')
        map_val = val
        map_element = (map_key, map_val)
        c_dict.insert(map_element)
    return c_dict

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.cdivision(True)
cdef float impute_snp_from_offsprings(int snp,
                      int[:] sib_indexes,
                      int[:, :] snp_ibd0,
                      int[:, :] snp_ibd1,
                      int[:, :] snp_ibd2,
                      float f,
                      int[:, :, :] phased_gts,
                      int[:, :] unphased_gts,
                      int[:, :, :] sib_hap_IBDs,
                      int len_snp_ibd0,
                      int len_snp_ibd1,
                      int len_snp_ibd2):
    """Imputes the parent sum divided by two for a single SNP from offsprings and returns the imputed value
    If phased_gts is not NULL, it tries to do the imputation with that first and if it's not usable, it falls back to unphased data.

    Args:
        snp : int
            index of each sibling between offsprings
        
        sib_indexes: int[:]
            Determines the gts index for each sibling from index of each sibling between offsprings

        snp_ibd0 : int[:,:]
            List of sib pairs that are ibd0 in this SNP. It is assumed that there are len_snp_ibd0 sib pairs is this list.

        snp_ibd1 : int[:,:]
            List of sib pairs that are ibd1 in this SNP. It is assumed that there are len_snp_ibd1 sib pairs is this list

        snp_ibd2 : int[:,:]
            List of sib pairs that are ibd2 in this SNP. It is assumed that there are len_snp_ibd2 sib pairs is this list

        f : float
            Minimum allele frequency for the SNP.

        phased_gts : int[:,:,:]
            A three-dimensional array containing genotypes for all individuals, SNPs and, haplotypes respectively.

        unphased_gts : int[:,:]
            A two-dimensional array containing genotypes for all individuals and SNPs respectively.
        
        sib_hap_IBDs: int[:, :, :]
            The IBD statuses of haplotypes. For each pair of siblings, first index is obtained by get_hap_index.
            Second index determines which haplotype pair(0 is 0-0, 1 is 0-1, 2 is 1-0, 3 is 1-1),
            third index the location of interest on the haplotypes

        len_snp_ibd0 : int
            The number of sibling pairs in snp_ibd0.

        len_snp_ibd1 : int
            The number of sibling pairs in snp_ibd1.

        len_snp_ibd2 : int
            The number of sibling pairs in snp_ibd2.

    Returns:
        float
            Imputed parent sum divided by two. NAN if all the children are NAN in this SNP.

    """

    cdef float result = nan_float
    cdef float additive
    cdef int sibsum = 0
    cdef int counter, sib1, sib2, pair_index, sib_index1, sib_index2, hap_index, h00, h01, h10, h11, gs10, gs11, gs20, gs21


    if phased_gts != None:
        # The only time that having phased data matters is when we have IBD1
        if len_snp_ibd0==0 and len_snp_ibd1>0:
            result = 0
            counter = 0
            for pair_index in range(len_snp_ibd1):
                sib1 = snp_ibd1[pair_index, 0]
                sib2 = snp_ibd1[pair_index, 1]
                sib_index1 = sib_indexes[sib1]
                sib_index2 = sib_indexes[sib2]
                hap_index = get_hap_index(sib1, sib2)
                h00 = sib_hap_IBDs[hap_index, 0, snp]
                h01 = sib_hap_IBDs[hap_index, 1, snp]
                h10 = sib_hap_IBDs[hap_index, 2, snp]
                h11 = sib_hap_IBDs[hap_index, 3, snp]
                
                gs10 = phased_gts[sib_index1, snp, 0]
                gs11 = phased_gts[sib_index1, snp, 1]
                gs20 = phased_gts[sib_index2, snp, 0]
                gs21 = phased_gts[sib_index2, snp, 1]
                #checks whether inferred haplotype IBDs are consistend with the given IBD status
                if h00+h01+h10+h11 == 1:
                    # From the four observed alleles two are shared. So the imputation result is sum of f and the three distinct alleles divided by two.
                    if h00==1:
                        result += (f + gs10 + gs11 + gs21)/2
                    if h01==1:
                        result += (f + gs10 + gs11 + gs20)/2
                    if h10==1:
                        result += (f + gs11 + gs10 + gs21)/2
                    if h11==1:
                        result += (f + gs11 + gs10 + gs20)/2
                    counter += 1
                    
            if counter>0:
                return result/counter

    if len_snp_ibd0 > 0:
        #if there is any ibd state0 we have observed all of the parents' genotypes,
        #therefore we can discard other ibd statuses
        result = 0        
        for pair_index in range(len_snp_ibd0):
            sib1 = sib_indexes[snp_ibd0[pair_index, 0]]
            sib2 = sib_indexes[snp_ibd0[pair_index, 1]]
            result += (unphased_gts[sib1, snp]+unphased_gts[sib2, snp])
        result = result/len_snp_ibd0

    elif len_snp_ibd1 > 0:
        #Because ibd2 is similar to having just one individual, we can discard ibd2s
        result = 0
        for pair_index in range(len_snp_ibd1):
            sib1 = sib_indexes[snp_ibd1[pair_index, 0]]
            sib2 = sib_indexes[snp_ibd1[pair_index, 1]]
            sibsum = (unphased_gts[sib1, snp]+unphased_gts[sib2, snp])
            additive = 0
            if sibsum==0:
                additive = f
            elif sibsum==1:
                additive = 1+f
                #TODO figure out whether this is true this should be 1.5+f
            elif sibsum==2:
                additive = 1+2*f
            elif sibsum==3:
                additive = 2+f
            elif sibsum==4:
                additive = 3+f
            result += additive
        result = result/len_snp_ibd1

    elif len_snp_ibd2 > 0:
        #As ibd2 simillar to having one individual, we dividsnpe the sum of the pair by two
        result = 0
        for pair_index in range(len_snp_ibd2):
            sib1 = sib_indexes[snp_ibd2[pair_index, 0]]
            sib2 = sib_indexes[snp_ibd2[pair_index, 1]]
            result += (unphased_gts[sib1, snp]+unphased_gts[sib2, snp])/2. + 2*f
        result = result/len_snp_ibd2

    return result/2

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.cdivision(True)
cdef float impute_snp_from_parent_offsprings(int snp,
                      int parent,
                      int[:] sib_indexes,
                      int[:, :] snp_ibd0,
                      int[:, :] snp_ibd1,
                      int[:, :] snp_ibd2,
                      float f,
                      int[:, :, :] phased_gts,
                      int[:, :] unphased_gts,
                      int[:, :, :] sib_hap_IBDs,
                      int[:, :, :] parent_offspring_hap_IBDs,
                      int len_snp_ibd0,
                      int len_snp_ibd1,
                      int len_snp_ibd2,
                      ):
    """Imputes the missing parent for a single SNP from the other parent and offsprings and returns the imputed value
    
    If returns Nan if there are no sibling pairs that can be children of the existing parent.

    Args:
        snp : int
            The SNP index

        parent : int
            The index of parent's row in the bed matrix

        sib_indexes: int[:]
            Determines the gts index for each sibling from index of each sibling between offsprings

        snp_ibd0 : cnp.ndarray[cnp.int_t, ndim=2]
            List of sib pairs that are ibd0 in this SNP. It is assumed that there are len_snp_ibd0 sib pairs is this list.

        snp_ibd1 : cnp.ndarray[cnp.int_t, ndim=2]
            List of sib pairs that are ibd1 in this SNP. It is assumed that there are len_snp_ibd1 sib pairs is this list

        snp_ibd2 : cnp.ndarray[cnp.int_t, ndim=2]
            List of sib pairs that are ibd2 in this SNP. It is assumed that there are len_snp_ibd2 sib pairs is this list

        f : float
            Minimum allele frequency for the SNP.

        phased_gts : int[:,:,:]
            A three-dimensional array containing genotypes for all individuals, SNPs and, haplotypes respectively.

        unphased_gts : int[:,:]
            A two-dimensional array containing genotypes for all individuals and SNPs respectively.

        sib_hap_IBDs: int[:, :, :]
            The IBD statuses of haplotypes. For each pair of siblings, first index is obtained by get_hap_index.
            Second index determines which haplotype pair(0 is 0-0, 1 is 0-1, 2 is 1-0, 3 is 1-1),
            third index the location of interest on the haplotypes

        parent_offspring_hap_IBDs: int[:, :, :]
            The IBD statuses of haplotypes. For each pair of parent offspring, first index is obtained by sib index between siblings.
            Second index determines which haplotype pair(0 is 0-0, 1 is 0-1, 2 is 1-0, 3 is 1-1),
            third index the location of interest on the haplotypes

        len_snp_ibd0 : int
            The number of sibling pairs in snp_ibd0.

        len_snp_ibd1 : int
            The number of sibling pairs in snp_ibd1.

        len_snp_ibd2 : int
            The number of sibling pairs in snp_ibd2.

    Returns:
        float
            Imputed missing parent. NAN if all the children are NAN in this SNP.

    """

    cdef float result
    cdef float additive
    cdef int gs1, gs2
    cdef float sibsum = 0
    cdef int sib1, sib2, pair_index, counter, sib_index1, sib_index2, hap_index
    cdef int sibs_h00, sibs_h01, sibs_h10, sibs_h11, sibship_shared_allele_sib1, sibship_shared_allele_sib2
    cdef int parent_sib1_h00, parent_sib1_h01, parent_sib1_h10, parent_sib1_h11, parent_offspring1_shared_allele_parent, parent_offspring1_shared_allele_offspring
    cdef int parent_sib2_h00, parent_sib2_h01, parent_sib2_h10, parent_sib2_h11, parent_offspring2_shared_allele_parent, parent_offspring2_shared_allele_offspring
    cdef float gp = unphased_gts[parent, snp]
    if phased_gts != None:
        #having phased data does not matter with IBD state 0
        if len_snp_ibd0==0 and len_snp_ibd1>0:
            result = 0
            counter = 0
            for pair_index in range(len_snp_ibd1):
                sib1 = snp_ibd1[pair_index, 0]
                sib2 = snp_ibd1[pair_index, 1]
                sib_index1 = sib_indexes[sib1]
                sib_index2 = sib_indexes[sib2]
                hap_index = get_hap_index(sib1, sib2)
                sibs_h00 = sib_hap_IBDs[hap_index, 0, snp]
                sibs_h01 = sib_hap_IBDs[hap_index, 1, snp]
                sibs_h10 = sib_hap_IBDs[hap_index, 2, snp]
                sibs_h11 = sib_hap_IBDs[hap_index, 3, snp]
                sibship_shared_allele_sib1 = sibs_h10 + sibs_h11
                sibship_shared_allele_sib2 = sibs_h01 + sibs_h11
                #checks inferred haplotype IBDs are consistent with the given IBD status
                if sibs_h00 + sibs_h10 + sibs_h01 + sibs_h11 != 1:
                    continue

                parent_sib1_h00 = parent_offspring_hap_IBDs[sib1, 0, snp]
                parent_sib1_h01 = parent_offspring_hap_IBDs[sib1, 1, snp]
                parent_sib1_h10 = parent_offspring_hap_IBDs[sib1, 2, snp]
                parent_sib1_h11 = parent_offspring_hap_IBDs[sib1, 3, snp]
                parent_offspring1_shared_allele_parent = parent_sib1_h10 + parent_sib1_h11
                parent_offspring1_shared_allele_offspring = parent_sib1_h01 + parent_sib1_h11
                #checks inferred haplotype IBDs are consistent with the natural IBD status
                if parent_sib1_h00 + parent_sib1_h10 + parent_sib1_h01 + parent_sib1_h11 != 1:
                    continue

                parent_sib2_h00 = parent_offspring_hap_IBDs[sib2, 0, snp]
                parent_sib2_h01 = parent_offspring_hap_IBDs[sib2, 1, snp]
                parent_sib2_h10 = parent_offspring_hap_IBDs[sib2, 2, snp]
                parent_sib2_h11 = parent_offspring_hap_IBDs[sib2, 3, snp]
                parent_offspring2_shared_allele_parent = parent_sib2_h10 + parent_sib2_h11
                parent_offspring2_shared_allele_offspring = parent_sib2_h01 + parent_sib2_h11
                #checks inferred haplotype IBDs are consistent with the natural IBD status
                if parent_sib2_h00 + parent_sib2_h10 + parent_sib2_h01 + parent_sib2_h11 != 1:
                    continue

                if parent_offspring1_shared_allele_offspring == sibship_shared_allele_sib1 and parent_offspring2_shared_allele_offspring == sibship_shared_allele_sib2:
                    #if the allele shared between offspring is also shared between those and the existing parent
                    result += phased_gts[sib_index1, snp, 1-parent_offspring1_shared_allele_offspring]+phased_gts[sib_index2, snp, 1-parent_offspring2_shared_allele_offspring]
                    counter+=1

                elif parent_offspring1_shared_allele_offspring != sibship_shared_allele_sib1 and parent_offspring2_shared_allele_offspring != sibship_shared_allele_sib2:
                    #if the allele shared between offspring is not shared between those and the existing parent
                    result += phased_gts[sib_index2, snp, sibship_shared_allele_sib1]+f
                    counter+=1

            if counter > 0:
                return result/counter

        if len_snp_ibd0==0 and len_snp_ibd1==0 and len_snp_ibd2>0:
            result = 0
            counter = 0
            for pair_index in range(len_snp_ibd2):
                sib1 = snp_ibd2[pair_index, 0]
                sib2 = snp_ibd2[pair_index, 1]
                sib_index1 = sib_indexes[sib1]
                sib_index2 = sib_indexes[sib2]
                parent_sib1_h00 = parent_offspring_hap_IBDs[sib1, 0, snp]
                parent_sib1_h01 = parent_offspring_hap_IBDs[sib1, 1, snp]
                parent_sib1_h10 = parent_offspring_hap_IBDs[sib1, 2, snp]
                parent_sib1_h11 = parent_offspring_hap_IBDs[sib1, 3, snp]
                parent_offspring1_shared_allele_parent = parent_sib1_h10 + parent_sib1_h11
                parent_offspring1_shared_allele_offspring = parent_sib1_h01 + parent_sib1_h11
                #checks inferred haplotype IBDs are consistent with the natural IBD status
                if parent_sib1_h00 + parent_sib1_h10 + parent_sib1_h01 + parent_sib1_h11 != 1:
                    continue
                result += phased_gts[sib_index1, snp, 1-parent_offspring1_shared_allele_offspring]+f
                counter += 1
            if counter > 0:
                return result/counter

    result = nan_float
    counter = 0
    if len_snp_ibd0 > 0:
        #if there is any ibd state0 we have observed all of the parents' genotypes,
        #therefore we can discard other ibd statuses
        result = 0
        counter = 0
        for pair_index in range(len_snp_ibd0):
            sib1 = snp_ibd0[pair_index, 0]
            gs1 = unphased_gts[sib_indexes[sib1], snp]
            sib2 = snp_ibd0[pair_index, 1]
            gs2 = unphased_gts[sib_indexes[sib2], snp]

            if not is_possible_child(<int> gs1, <int> gp) or not is_possible_child(<int> gs2, <int> gp):
                continue

            result += (gs1 + gs2)
            counter += 1

        if counter > 0:
            result = result/counter - gp
        else:
            result = nan_float

    elif len_snp_ibd1 > 0:
        #Because ibd2 is similar to having just one individual, we can discard ibd2s
        result = 0
        counter = 0

        for pair_index in range(len_snp_ibd1):
            sib1 = snp_ibd1[pair_index, 0]
            sib2 = snp_ibd1[pair_index, 1]
            gs1 = unphased_gts[sib_indexes[sib1], snp]
            gs2 = unphased_gts[sib_indexes[sib2], snp]

            if not is_possible_child(<int> gs1, <int> gp) or not is_possible_child(<int> gs2, <int> gp):
                continue
            
            additive = 0
            if gp == 0 and (gs1 == 0 and gs2 == 0):
                additive = 0.5*f*(1-f)/((1-f)**2 + 0.5*f*(1-f))
                counter +=1
            
            elif gp == 0 and ((gs1 == 0 and gs2 == 1) or (gs1 == 1 and gs2 == 0)):
                additive = 1
                counter +=1

            elif gp == 0 and (gs1 == 1 and gs2 == 1):
                additive = (0.5*f*(1-f) + 2*f**2)/(0.5*f*(1-f)+f**2)
                counter +=1

            elif gp == 1 and (gs1 == 0 and gs2 == 0):
                additive = 0
                counter +=1
            
            elif gp == 1 and ((gs1 == 0 and gs2 == 1) or (gs1 == 1 and gs2 == 0)):
                additive = f*(1-f)/(0.5*(1-f)**2 + f*(1-f))
                counter +=1

            elif gp == 1 and (gs1 == 1 and gs2 == 1):
                additive = 0.5*f**2/(0.25*f**2 + 0.25*(1-f)**2)
                counter +=1

            elif gp == 1 and ((gs1 == 1 and gs2 == 2) or (gs1 == 2 and gs2 == 1)):
                additive = f*(1-f)/(f*(1-f) + 0.5*f**2) + f**2/(f*(1-f) + 0.5*f**2)
                counter +=1

            elif gp == 1 and (gs1 == 2 and gs2 == 2):
                additive = 2
                counter +=1
            
            elif gp == 2 and (gs1 == 1 and gs2 == 1):
                additive = 0.5*f*(1-f)/(0.5*f*(1-f)+(1-f)**2)
                counter +=1

            elif gp == 2 and ((gs1 == 1 and gs2 == 2) or (gs1 == 2 and gs2 == 1)):
                additive = 1
                counter +=1

            elif gp == 2 and (gs1 == 2 and gs2 == 2):
                additive = 0.5*f*(1-f)/(0.5*f*(1-f) + f**2) + 2*f**2/(0.5*f*(1-f) + f**2)
                counter +=1

            result += additive

        if counter > 0 :
            result = result/counter
        else:            
            result = nan_float
    
    
    elif len_snp_ibd2 > 0:
        #As ibd2 simillar to having one individual, we dividsnpe the sum of the pair by two
        result = 0
        counter = 0
        for pair_index in range(len_snp_ibd2):
            sib1 = snp_ibd2[pair_index, 0]
            sib2 = snp_ibd2[pair_index, 1]
            gs1 = unphased_gts[sib_indexes[sib1], snp]
            gs2 = unphased_gts[sib_indexes[sib2], snp]

            if not is_possible_child(<int> gs1, <int> gp) or not is_possible_child(<int> gs2, <int> gp):
                continue

            additive = 0    
            if gs1 == gs2:
                if gp == 0 and gs1 == 0:
                    additive = f*(1-f)/((1-f)**2 + f*(1-f))
                    counter += 1

                elif gp == 0 and gs1 == 1:
                    additive = (f*(1-f) + 2*(f**2))/(f*(1-f) + f**2)
                    counter += 1

                elif gp == 1 and gs1 == 0:
                    additive = 0.5*f*(1-f)/(0.5*f*(1-f) + 0.5*(1-f)**2)
                    counter += 1

                elif gp == 1 and gs1 == 1:
                    additive = (f*(1-f) + f**2)/(0.5*(1-f)**2 + f*(1-f) + 0.5*f**2)
                    counter += 1

                elif gp == 1 and gs1 == 2:
                    additive = (0.5*f*(1-f) + f**2)/(0.5*f*(1-f) + 0.5*f**2)
                    counter += 1

                elif gp == 2 and gs1 == 1:
                    additive = f*(1-f)/((1-f)**2 + f*(1-f))
                    counter += 1

                elif gp == 2 and gs1 == 2:
                    additive = (f*(1-f) + 2*f**2)/(f*(1-f) + f**2)
                    counter += 1

            result += additive
            
        if counter > 0:
            result = result/counter
        else:
            result = nan_float

    return result    

cdef int get_IBD_type(cstring id1,
                      cstring id2,
                      int loc,
                      cmap[cpair[cstring, cstring], vector[int]]& ibd_dict) nogil:
    """Returns the IBD status of individuals with id1 and id2 in the SNP located at loc

    Args:
        id1 : cstring
            IID of individual 1

        id2 : cstring
            IID of individual 2

        loc : int
            Location of the SNP

        ibd_dict : cmap[cpair[cstring, cstring], vector[int]]
            A dictionary containing flattened IBD segments for each pair of related individuals.
            Each segment consists of three integers, start, end, and IBD_status (start and end are inclusive).
            Values are lists of integers in this fashion: [start0, end0, ibd_status0, start2, end2, ibd_status2, ...]
            Sibreg.bin.preprocess_data.prepare_data can be used to create this.

    Returns:
        int
            the IBD status of individuals with id1 and id2 in the SNP located at loc

    """

    #the value for ibd_dict is like this: [start1, end1, ibd_type1, start2, end2, ibd_type2,...]
    cdef int result = 0
    cdef int index
    cdef cpair[cstring, cstring] key1
    cdef cpair[cstring, cstring] key2
    cdef vector[int] segments
    key1.first = id1
    key1.second = id2
    key2.first = id2
    key2.second = id1

    if ibd_dict.count(key1) > 0:
        segments = ibd_dict[key1]

    elif ibd_dict.count(key2) > 0:
        segments = ibd_dict[key2]

    for index in range(segments.size()//3):
        if segments[3*index] <= loc <= segments[3*index+1]:
            result = segments[3*index+2]
            break

    return result

@cython.wraparound(False)
@cython.boundscheck(False)
def impute(sibships, iid_to_bed_index,  phased_gts, unphased_gts, ibd, pos, hdf5_output_dict, chromosome, output_address = None, threads = None, output_compression = None, output_compression_opts = None, half_window=50, ibd_threshold = 0.999):
    """Does the parent sum imputation for families in sibships and all the SNPs in unphased_gts and returns the results.

    Inputs and outputs of this function are ascii bytes instead of strings

    Args:
        sibships : pandas.Dataframe
            A pandas DataFrame with columns ['FID', 'FATHER_ID', 'MOTHER_ID', 'IID'] where IID columns is a list of the IIDs of individuals in that family.
            It only contains families with more than one child. The parental sum is computed for all these families.

        iid_to_bed_index : str->int
            A dictionary mapping IIDs of people to their location in the bed file.

        phased_gts : numpy.array
            Numpy array containing the phased genotype data. Axes are individulas and SNPS respectively.

        unphased_gts : numpy.array
            Numpy array containing the unphased genotype data from a bed file. Axes are individulas, SNPS and haplotype number respectively.

        ibd : pandas.Dataframe
            A pandas DataFrame with columns "ID1", "ID2", 'segment'. The segments column is a list of IBD segments between ID1 and ID2.
            Each segment consists of a start, an end, and an IBD status. The segment list is flattened meaning it's like [start0, end0, ibd_status0, start1, end1, ibd_status1, ...]

        pos : numpy.array
            A numpy array with the position of each SNP in the order of appearance in phased and unphased gts.
        
        hdf5_output_dict : dict
            Other key values to be added to the HDF5 output

        chromosome: str
            Name of the chromosome(s) that's going to be imputed. Only used for logging purposes.

        output_address : str, optional
            If presented, the results would be written to this address in HDF5 format.
            The following table explains the keys and their corresponding values within this file.
                'imputed_par_gts' : imputed genotypes
                'pos' : the position of SNPs(in the order of appearance in genotypes)
                "bim_columns" : Columns of the resulting bim file
                "bim_values" : Contents of the resulting bim file
                'pedigree' : pedigree table
                'families' : family ids of the imputed parents(in the order of appearance in genotypes)
                'parental_status' : a numpy array where each row shows the family status of the family of the corresponding row in families.
                    Its columns are has_father, has_mother, single_parent respectively.
        
        threads : int, optional
            Specifies the Number of threads to be used. If None there will be only one thread.

        output_compression : str
            Optional compression algorithm used in writing the output as an hdf5 file. It can be either gzip or lzf. None means no compression.

        output_compression_opts : int
            Additional settings for the optional compression algorithm. Take a look at the create_dataset function of h5py library for more information. None means no compression setting.
        
        half_window : int, optional
            For each location i, the IBD inference for the haplotypes is restricted to [i-half_window, i+half_window].

        ibd_threshold : float, optional
            Minimum ratio of agreement between haplotypes for declaring IBD.

    Returns:
        tuple(list, numpy.array)
            The second element is imputed parental genotypes and the first element is family ids of the imputed parents(in the order of appearance in the first element).
            
    """
    logging.warning("with chromosome " + str(chromosome)+": " + "imputing ...")
    if sibships.empty:
        logging.warning("with chromosome " + str(chromosome)+": " + "Error: No families to be imputed")
        return [], np.array()

    cdef int number_of_threads = 1
    if threads is not None:
        number_of_threads = threads
    logging.info("with chromosome " + str(chromosome)+": " + "imputing data ...")
    #converting python obejcts to c
    #sibships
    cdef int max_sibs = np.max(sibships["sib_count"])
    cdef int max_ibd_pairs = max_sibs*(max_sibs-1)//2
    cdef int number_of_fams = sibships.shape[0]
    cdef cnp.ndarray[cnp.double_t, ndim=1]freqs = np.nanmean(unphased_gts,axis=0)/2.0
    sibships["parent"] = sibships["FATHER_ID"]
    sibships["parent"][sibships["has_father"]] = sibships["FATHER_ID"][sibships["has_father"]]
    sibships["parent"][sibships["has_mother"]] = sibships["MOTHER_ID"][sibships["has_mother"]]
    cdef vector[cstring] parents
    cdef vector[vector[cstring]] fams
    for fam in range(number_of_fams):
        fams.push_back(sibships["IID"].iloc[fam])
        parents.push_back(sibships["parent"].iloc[fam])

    cdef int[:] sib_count = sibships["sib_count"].values.astype("i")
    cdef cnp.ndarray[cnp.uint8_t, ndim=1] single_parent = sibships["single_parent"].astype('uint8').values    
    #iid_to_bed_index
    cdef cmap[cstring, int] c_iid_to_bed_index = iid_to_bed_index
    #unphased_gts
    cdef int[:, :] c_unphased_gts = unphased_gts
    cdef int[:, :, :] c_phased_gts = phased_gts
    cdef int number_of_snps = c_unphased_gts.shape[1]
    #ibd
    cdef cmap[cpair[cstring, cstring], vector[int]] c_ibd = dict_to_cmap(ibd)
    #pos
    cdef cnp.ndarray[cnp.int_t, ndim=1] c_pos = pos

    cdef int len_snp_ibd0 = 0
    cdef int len_snp_ibd1 = 0
    cdef int len_snp_ibd2 = 0
    cdef int[:,:,:] snp_ibd0 = np.ones([number_of_threads, max_ibd_pairs, 2], dtype=np.dtype("i"))
    cdef int[:,:,:] snp_ibd1 = np.ones([number_of_threads, max_ibd_pairs, 2], dtype=np.dtype("i"))
    cdef int[:,:,:] snp_ibd2 = np.ones([number_of_threads, max_ibd_pairs, 2], dtype=np.dtype("i"))
    cdef int i, j, loc, ibd_type, sib1_index, sib2_index, progress, where
    cdef cstring sib1_id, sib2_id
    cdef int[:, :] sibs_index = np.zeros((number_of_threads, max_sibs)).astype("i")
    cdef double[:,:] imputed_par_gts = np.zeros((number_of_fams, number_of_snps))
    cdef int snp, this_thread, sib1_gene_isnan, sib2_gene_isnan, index
    byte_chromosome = chromosome.encode("ASCII")
    cdef char* chromosome_c = byte_chromosome
    cdef int mod = (number_of_fams+1)//100
    #For hap_ibds, axes denote thread, individual pair, haplotypes and SNPs.
    cdef int [:,:,:,:] sib_hap_IBDs = np.ones([number_of_threads, max_ibd_pairs, 4, number_of_snps], dtype=np.dtype("i"))
    cdef int [:,:,:,:] parent_offspring_hap_IBDs = np.ones([number_of_threads, max_sibs, 4, number_of_snps], dtype=np.dtype("i"))
    cdef double[:, :] agreement_percentages = np.zeros((number_of_threads, number_of_snps))
    cdef int[:, :] agreement_counts = np.ones([number_of_threads, number_of_snps], dtype=np.dtype("i"))
    cdef int half_window_c = half_window
    cdef float ibd_threshold_c = ibd_threshold
    reset()
    logging.info("with chromosome " + str(chromosome)+": " + "using "+str(threads)+" threads")
    for index in range(number_of_fams):#prange(number_of_fams, nogil = True, num_threads = number_of_threads):
        report(mod, chromosome_c, number_of_fams)
        this_thread = openmp.omp_get_thread_num()
        for i in range(sib_count[index]):
            sibs_index[this_thread, i] = c_iid_to_bed_index[fams[index][i]]        
        if c_phased_gts != None:
            # First fills hap_ibds
            for i in range(1, sib_count[index]):
                for j in range(i):
                    where = get_hap_index(i, j)
                    get_IBD(c_phased_gts[sibs_index[this_thread, i],:,0], c_phased_gts[sibs_index[this_thread, j],:,0], number_of_snps, half_window_c, ibd_threshold_c, agreement_counts[this_thread, :], agreement_percentages[this_thread, :], sib_hap_IBDs[this_thread, where, 0, :])
                    get_IBD(c_phased_gts[sibs_index[this_thread, i],:,0], c_phased_gts[sibs_index[this_thread, j],:,1], number_of_snps, half_window_c, ibd_threshold_c, agreement_counts[this_thread, :], agreement_percentages[this_thread, :], sib_hap_IBDs[this_thread, where, 1, :])
                    get_IBD(c_phased_gts[sibs_index[this_thread, i],:,1], c_phased_gts[sibs_index[this_thread, j],:,0], number_of_snps, half_window_c, ibd_threshold_c, agreement_counts[this_thread, :], agreement_percentages[this_thread, :], sib_hap_IBDs[this_thread, where, 2, :])
                    get_IBD(c_phased_gts[sibs_index[this_thread, i],:,1], c_phased_gts[sibs_index[this_thread, j],:,1], number_of_snps, half_window_c, ibd_threshold_c, agreement_counts[this_thread, :], agreement_percentages[this_thread, :], sib_hap_IBDs[this_thread, where, 3, :])
            
            if single_parent[index]:
                for i in range(0, sib_count[index]):
                    get_IBD(c_phased_gts[c_iid_to_bed_index[parents[index]],:,0], c_phased_gts[sibs_index[this_thread, i],:,0], number_of_snps, half_window_c, ibd_threshold_c, agreement_counts[this_thread, :], agreement_percentages[this_thread, :], parent_offspring_hap_IBDs[this_thread, i, 0, :])
                    get_IBD(c_phased_gts[c_iid_to_bed_index[parents[index]],:,0], c_phased_gts[sibs_index[this_thread, i],:,1], number_of_snps, half_window_c, ibd_threshold_c, agreement_counts[this_thread, :], agreement_percentages[this_thread, :], parent_offspring_hap_IBDs[this_thread, i, 1, :])
                    get_IBD(c_phased_gts[c_iid_to_bed_index[parents[index]],:,1], c_phased_gts[sibs_index[this_thread, i],:,0], number_of_snps, half_window_c, ibd_threshold_c, agreement_counts[this_thread, :], agreement_percentages[this_thread, :], parent_offspring_hap_IBDs[this_thread, i, 2, :])
                    get_IBD(c_phased_gts[c_iid_to_bed_index[parents[index]],:,1], c_phased_gts[sibs_index[this_thread, i],:,1], number_of_snps, half_window_c, ibd_threshold_c, agreement_counts[this_thread, :], agreement_percentages[this_thread, :], parent_offspring_hap_IBDs[this_thread, i, 3, :])
        snp = 0
        while snp < number_of_snps:
            len_snp_ibd0 = 0
            len_snp_ibd1 = 0
            len_snp_ibd2 = 0
            loc = c_pos[snp]
            if sib_count[index] > 1:
                for i in range(1, sib_count[index]):
                    for j in range(i):
                        sib1_index = sibs_index[this_thread, i]
                        sib2_index = sibs_index[this_thread, j]
                        sib1_id = fams[index][i]
                        sib2_id = fams[index][j]
                        sib1_gene_isnan = isnan(c_unphased_gts[sib1_index, snp])
                        sib2_gene_isnan = isnan(c_unphased_gts[sib2_index, snp])
                        ibd_type = get_IBD_type(sib1_id, sib2_id, loc, c_ibd)
                        if sib1_gene_isnan  and sib2_gene_isnan:
                            continue
                        elif not sib1_gene_isnan  and sib2_gene_isnan:
                            snp_ibd2[this_thread, len_snp_ibd2,0] = i
                            snp_ibd2[this_thread, len_snp_ibd2,1] = i
                            len_snp_ibd2 = len_snp_ibd2+1

                        elif sib1_gene_isnan  and not sib2_gene_isnan:
                            snp_ibd2[this_thread, len_snp_ibd2,0] = j
                            snp_ibd2[this_thread, len_snp_ibd2,1] = j
                            len_snp_ibd2 = len_snp_ibd2 + 1

                        elif not sib1_gene_isnan and not sib2_gene_isnan:
                            if ibd_type == 2:
                                snp_ibd2[this_thread, len_snp_ibd2,0] = i
                                snp_ibd2[this_thread, len_snp_ibd2,1] = j
                                len_snp_ibd2 = len_snp_ibd2 + 1
                            if ibd_type == 1:
                                snp_ibd1[this_thread, len_snp_ibd1,0] = i
                                snp_ibd1[this_thread, len_snp_ibd1,1] = j
                                len_snp_ibd1 = len_snp_ibd1 + 1
                            if ibd_type == 0:
                                snp_ibd0[this_thread, len_snp_ibd0,0] = i
                                snp_ibd0[this_thread, len_snp_ibd0,1] = j
                                len_snp_ibd0 = len_snp_ibd0 + 1
            else :
                sib1_index = sibs_index[this_thread, 0]
                if not isnan(c_unphased_gts[sib1_index, snp]):
                    snp_ibd2[this_thread, len_snp_ibd2,0] = 0
                    snp_ibd2[this_thread, len_snp_ibd2,1] = 0
                    len_snp_ibd2 = len_snp_ibd2 + 1
            if single_parent[index]:
                imputed_par_gts[index, snp] = impute_snp_from_parent_offsprings(snp,
                                                                                c_iid_to_bed_index[parents[index]],
                                                                                sibs_index[this_thread, :],
                                                                                snp_ibd0[this_thread,:,:],
                                                                                snp_ibd1[this_thread,:,:],
                                                                                snp_ibd2[this_thread,:,:],
                                                                                freqs[snp],
                                                                                c_phased_gts,
                                                                                c_unphased_gts,
                                                                                sib_hap_IBDs[this_thread,:,:,:],
                                                                                parent_offspring_hap_IBDs[this_thread,:,:,:],
                                                                                len_snp_ibd0,
                                                                                len_snp_ibd1,
                                                                                len_snp_ibd2
                                                                                )
            else:
                imputed_par_gts[index, snp] = impute_snp_from_offsprings(snp,
                                                                         sibs_index[this_thread, :],
                                                                         snp_ibd0[this_thread,:,:],
                                                                         snp_ibd1[this_thread,:,:],
                                                                         snp_ibd2[this_thread,:,:],
                                                                         freqs[snp],
                                                                         c_phased_gts,
                                                                         c_unphased_gts,
                                                                         sib_hap_IBDs[this_thread,:,:,:],
                                                                         len_snp_ibd0,
                                                                         len_snp_ibd1,
                                                                         len_snp_ibd2)
            snp = snp+1
    destroy()
    if output_address is not None:
        logging.info("with chromosome " + str(chromosome)+": " + "Writing the results as a hdf5 file to "+output_address + ".hdf5")
        with h5py.File(output_address+".hdf5",'w') as f:
            f.create_dataset('imputed_par_gts',(number_of_fams, number_of_snps),dtype = 'float16', chunks = True, compression = output_compression, compression_opts=output_compression_opts, data = imputed_par_gts)
            f['families'] = np.array(sibships["FID"].values, dtype='S')
            f['parental_status'] = sibships[["has_father", "has_mother", "single_parent"]]
            f['pos'] = pos
            f["bim_columns"] = np.array(hdf5_output_dict["bim_columns"], dtype='S')
            f["bim_values"] = np.array(hdf5_output_dict["bim_values"], dtype='S')
            f["pedigree"] =  np.array(hdf5_output_dict["pedigree"], dtype='S')
    return sibships["FID"].values.tolist(), np.array(imputed_par_gts)