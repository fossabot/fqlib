# cython: infertypes=True
# cython: language_level=3
# cython: c_string_type=unicode
# cython: c_string_encoding=ascii
# distutils: language=c++

DEF MAX_LINE_LEN = 1000
from fqlib.validators cimport ValidationLevel

import os
from . import validators
from .error import SingleReadValidationError, PairedReadValidationError

cdef class SingleFastQReader:
    """Class used to iterate over records in a FastQ file. Validation will be
    performed based on the level of validation set in the constructor. Eventually,
    we will add functionality to efficiently unpack only the needed parts of the
    FastQ file.

    Args:
        filename (char*): name of the file being read as a C string.
        validation_level (str): String representing the stringency of validation 
            criteria. Must be one of the validation levels supported.
        lint_mode (str): String representing the stringency of linting criteria. Must 
            be one of the lint modes supported.

    Attributes:
        filename (str): name of the file being read as a Python string.
        basename (str): basename of the file being read as a Python string.
        cfile_handle (utils.CFileReader): handle to a fast implementation of a file reader
            written in C. This is used to iterate through the text file.
        rname (char[]): stack allocated character array that is reused each time a read
            is pulled from the file. This represents the "name" field.
        rsequence (char[]): stack allocated character array that is reused each time a 
            read is pulled from the file. This represents the "sequence" field.
        rplusline (char[]): stack allocated character array that is reused each time a 
            read is pulled from the file. This represents the "plusline" field.
        rquality (char[]): stack allocated character array that is reused each time a 
            read is pulled from the file. This represents the "quality" field.
        validation_level (validators.ValidationLevel): Must be one of the validation 
            levels supported.
        validators (list): Given a validation level, list of all single FastQ validators
            to be run on the reads as they are processed. This is constructed at 
            time of creation of the object.
        lint_mode (str): String representing the stringency of linting criteria. Must 
            be one of the lint modes supported.
        
    Raises:
        FileNotFoundError, ValueError
    """

    cdef public str filename
    cdef public str basename
    cdef public CFileReader cfile_handle
    cdef char[MAX_LINE_LEN] rname # Allocated on stack.
    cdef char[MAX_LINE_LEN] rsequence # Allocated on stack.
    cdef char[MAX_LINE_LEN] rplusline # Allocated on stack.
    cdef char[MAX_LINE_LEN] rquality # Allocated on stack.

    cdef public str lint_mode
    cdef public list validators
    cdef public ValidationLevel validation_level 

    def __cinit__(
        self,
        filename: str,
        validation_level: str = "high",
        lint_mode: str = "error"
    ):
        self.filename = filename
        self.basename = os.path.basename(self.filename)
        self.cfile_handle = CFileReader(filename)
        self.validation_level = validators.ValidationLevel(validation_level)
        self.lint_mode = lint_mode

        potential_validators = [
            (k, v()) for (k, v) in validators.__dict__.items()
            if not k.startswith("Base") and isinstance(v, type) and
            issubclass(v, validators.BaseSingleReadValidator)
        ]

        self.validators = [
            v for (k, v) in potential_validators if
            v.validation_level.level <= self.validation_level.level
        ]

    def __iter__(self):
        """Iterator methods."""
        return self

    def __next__(self):
        """Iterator methods."""

        # only check against read name because if any of the others are none, that 
        # should signal an incomplete read, not running out of reads in the file.
        read = dict(self.next_read())

        if read['name'] == "":
            raise StopIteration

        return read

    cpdef FastQRead next_read(self) except *:
        """Naively read the FastQ read. If something goes awry, expect it to get caught
        in the validators.

        Returns:
            FastQRead: a read from the FastQ file

        Raises:
            Error: many different types of errors may be thrown, especially 
                FastQ validation errors.
        """

        cdef FastQRead read

        strcpy(self.rname, self.cfile_handle.read_line()) # O(n)
        
        if strcmp(self.rname, "") == 0:
            fqread_init_empty(read)
            return read

        strcpy(self.rsequence, self.cfile_handle.read_line()) # O(n)
        strcpy(self.rplusline, self.cfile_handle.read_line()) # O(n)
        strcpy(self.rquality, self.cfile_handle.read_line()) # O(n)

        fqread_init(read, self.rname, self.rsequence, self.rplusline, self.rquality)

        # this suggests that there are no more reads left in the file.
        if strcmp(read.name, "") == 0:
            return read

        for validator in self.validators:
            result = validator.validate(read)
            if not result:
                description = validator.error
                if self.lint_mode == "error":
                    raise SingleReadValidationError(
                        description=description,
                        readname=read.name,
                        filename=self.basename,
                        lineno=self.cfile_handle.lineno
                    )
                elif self.lint_mode == "report":
                    print(
                        f"{self.basename}:{validator.code}:{self.cfile_handle.lineno}: " \
                        f"{description}"
                    )
                else:
                    raise NotImplementedError(
                        f"Not implemented for lint mode: {self.lint_mode}"
                    )

        return read


cdef class PairedFastQReader:
    """A class that steps through two FastQFiles at the same time and validates them
    from a global perspective.

    Args:
        read_one_filename (str): Path to the read one file.
        read_two_filename (str): Path to the read two file.
        lint_mode (str): Linting in 'error' or 'report' mode.
        single_read_validation_level (str): Validation level for the single read errors.
        paired_read_validation_level (str): Validation level for the paired read errors.
    """

    cdef public SingleFastQReader read_one_fastqfile
    cdef public SingleFastQReader read_two_fastqfile
    cdef public str lint_mode
    cdef public ValidationLevel validation_level 
    cdef public list validators
    cdef int _readno

    def __init__(
        self,
        read_one_filename: str,
        read_two_filename: str,
        lint_mode: str = "error",
        single_read_validation_level: str = "low",
        paired_read_validation_level: str = "low"
    ):
        self.read_one_fastqfile = SingleFastQReader(
            read_one_filename,
            validation_level=single_read_validation_level,
            lint_mode=lint_mode
        )
        self.read_two_fastqfile = SingleFastQReader(
            read_two_filename,
            validation_level=single_read_validation_level,
            lint_mode=lint_mode
        )
        self.lint_mode = lint_mode
        self.validation_level = validators.ValidationLevel(paired_read_validation_level)

        self._readno = 0

        potential_validators = [
            (k, v()) for (k, v) in validators.__dict__.items()
            if not k.startswith("Base") and isinstance(v, type) and
            issubclass(v, validators.BasePairedReadValidator)
        ]

        self.validators = [
            v for (k, v) in potential_validators if
            v.validation_level.level <= self.validation_level.level
        ]

    def __iter__(self):
        """Iterator methods."""
        return self

    def __next__(self):
        """Iterator methods."""
        result = self.next_readpair()
        self._readno += 1
        return result

    cpdef next_readpair(self):
        """Get the next pair of reads from both files.

        Returns:
            (FastQRead, FastQRead): tuple of both FastQRead objects, one from each file.

        Raises:
            Error: multiple errors may be thrown, especially FastQ validation errors
        """

        read_one = self.read_one_fastqfile.next_read()
        read_two = self.read_two_fastqfile.next_read()

        # Must be "and". If one is None and not the other, that's a mismatched FastQ
        # read in one of the files.
        if read_one.name == NULL and read_two.name == NULL:
            raise StopIteration

        for validator in self.validators:
            result = validator.validate(read_one, read_two)
            if not result:
                description = validator.error
                if self.lint_mode == "error":
                    raise PairedReadValidationError(
                        description=description,
                        read_one=read_one,
                        read_two=read_two,
                        read_pairno=self._readno,
                        read_one_fastqfile=self.read_one_fastqfile,
                        read_two_fastqfile=self.read_two_fastqfile
                    )
                elif self.lint_mode == "report":
                    print(
                        f"{self.read_one_fastqfile.basename}:{validator.code}:" \
                        f"{self._readno}: {description}"
                    )
                    print(
                        f"{self.read_two_fastqfile.basename}:{validator.code}:" \
                        f"{self._readno}: {description}"
                    )
                else:
                    raise NotImplementedError(
                        f"Not implemented for lint mode: {self.lint_mode}"
                    )

        return (read_one, read_two)

    def get_validators(self):
        """Returns a tuple with (SingleReadValidators, PairedReadValidators)"""
        sr_validators = [
            (v.code, v.__class__.__name__)
            for v in self.read_one_fastqfile.validators
        ]
        pr_validators = [
            (v.code, v.__class__.__name__) for v in self.validators
        ]
        return (sr_validators, pr_validators)