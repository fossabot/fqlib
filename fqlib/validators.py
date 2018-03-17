"""All validation logic for fqlib."""

import re
from abc import ABC, abstractmethod
from typing import Any


class ValidationLevel:
    """Utility class containing the various validation levels."""

    MINIMUM = 1
    LOW = 2
    HIGH = 3

    @staticmethod
    def resolve(value: Any):
        """Resolve an input to a ValidationLevel or throw an error.

        Args:
            value (Any): Any value that may be interpretted as a ValidationLevel.

        Throws:
            ValueError: if the input cannot be parsed, a ValueError is thrown.

        Returns:
            A validation level object corresponding to the input value.
        """

        if isinstance(value, ValidationLevel):
            return value
        elif isinstance(value, str):
            if value.lower() == "high":
                return ValidationLevel.HIGH
            elif value.lower() == 'low':
                return ValidationLevel.LOW
            elif value.lower() == 'minimum' or not value:
                return ValidationLevel.MINIMUM

        raise ValueError(f"Unknown single read validation level: {value}.")


class BaseSingleReadValidator(ABC):
    """Base validator for a single read, should not be called directly. This class
    is meant to be used as an abstract class for all single read FastQ validations.
    """

    @abstractmethod
    def validate(self, read):
        """Abstract validation method for single read validators."""
        raise NotImplementedError(
            f"'validate' not implemented for {self.__class__.__name__}"
        )


class BasePairedReadValidator(ABC):
    """Base validator for paired reads, should not be called directly. This class
    is meant to be used as an abstract class for all paired read FastQ validations.
    """

    @abstractmethod
    def validate(self, readone, readtwo):
        """Abstract validation method for paired read validators."""
        raise NotImplementedError(
            f"'validate' not implemented for {self.__class__.__name__}"
        )


class PluslineValidator(BaseSingleReadValidator):
    """Validates that the plusline of the FastQ file is correctly set to '+'."""

    level = ValidationLevel.MINIMUM
    code = "S001"

    def validate(self, read):
        if not read.plusline or read.plusline != '+':
            return False, f"The plusline is not formatted correctly. " \
                          f"It's possible this is a FastA file or that the reads "\
                          f"are not correctly formed."

        return True, None


class AlphabetValidator(BaseSingleReadValidator):
    """Verifies that all reads are in the AGCTN dictionary."""

    level = ValidationLevel.LOW
    code = "S002"

    def validate(self, read):
        if re.search("[^ACGTNacgtn]", read.sequence):
            return False, f'Non-ACTGN base found in sequence {read.sequence}'

        return True, None


class ReadnameValidator(BaseSingleReadValidator):
    """Validates that a readname is well-formed (locally, not globally) for
    errors like duplicate read names."""

    level = ValidationLevel.HIGH
    code = "S003"

    def validate(self, read):
        if not read.name.startswith("@"):
            return False, 'Read name must start with @'

        return True, None


class CompleteReadValidator(BaseSingleReadValidator):
    """Validates that the plusline of the FastQ file is correctly set to '+'."""

    level = ValidationLevel.MINIMUM
    code = "S004"

    def validate(self, read):
        if not read.name or not read.sequence or not read.plusline or not read.quality:
            return False, f"Read is not complete."

        return True, None


class PairedReadnameValidator(BasePairedReadValidator):
    """Validates that a pair of readnames are well-formed."""

    level = ValidationLevel.LOW
    code = "P001"

    def validate(self, readone, readtwo):
        if not readone.name == readtwo.name:
            return False, 'Read names do not match.'

        return True, None
