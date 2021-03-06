from setuptools import Extension, setup
from Cython.Build import cythonize
import numpy

ext_modules = [
    Extension(
        "tests.test_impute_from_sibs",
        ["tests/test_impute_from_sibs.pyx"],
        extra_compile_args=['-fopenmp'],
        extra_link_args=['-fopenmp'],
        language = "c++"
    )
]

setup(
    name='test sib imputation',
    ext_modules=cythonize(ext_modules),
    include_dirs=[numpy.get_include()]

)
