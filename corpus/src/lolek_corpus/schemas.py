"""Pydantic schemas for untrusted corpus-owned JSON formats."""

from __future__ import annotations

from typing import Annotated, Literal, Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    field_validator,
    model_validator,
)

from lolek_corpus.model import (
    CasePolicy,
    CorpusCase,
    CorpusMediaKind,
    CorpusPolicy,
    ExpectedResult,
    ExtractorSource,
    FailureReason,
    HarnessError,
    Outcome,
    Profile,
    Service,
    TelegramMediaKind,
    TerminalResult,
)

type _NonEmptyString = Annotated[str, Field(min_length=1, strict=True)]
type _NonNegativeInteger = Annotated[int, Field(ge=0, strict=True)]


class _InputModel(BaseModel):
    """Base for validated data read from corpus-owned JSON formats."""

    model_config = ConfigDict(extra="forbid", frozen=True)


class CorpusCaseInput(_InputModel):
    """Validated JSON representation of one upstream corpus case."""

    id: _NonEmptyString
    service: Service
    sources: Annotated[list[ExtractorSource], Field(min_length=1, strict=True)]
    kinds: Annotated[list[CorpusMediaKind], Field(min_length=1, strict=True)]
    url: _NonEmptyString

    @field_validator("sources")
    @classmethod
    def sources_are_unique(
        cls, sources: list[ExtractorSource]
    ) -> list[ExtractorSource]:
        """Reject duplicate provenance instead of silently discarding it."""
        if len(sources) != len(set(sources)):
            raise ValueError("contains duplicate values")
        return sources

    @field_validator("kinds")
    @classmethod
    def kinds_are_unique(cls, kinds: list[CorpusMediaKind]) -> list[CorpusMediaKind]:
        """Reject duplicate media kinds instead of silently discarding them."""
        if len(kinds) != len(set(kinds)):
            raise ValueError("contains duplicate values")
        return kinds

    def to_domain(self) -> CorpusCase:
        """Return the immutable domain object consumed by the runner."""
        return CorpusCase(
            id=self.id,
            service=self.service,
            sources=frozenset(self.sources),
            kinds=tuple(self.kinds),
            url=self.url,
        )


class _ExpectedResultInput(_InputModel):
    """Validated JSON representation of one expected terminal result."""

    terminal_result: _NonEmptyString
    media_count: _NonNegativeInteger | None = None
    media_kinds: Annotated[list[TelegramMediaKind], Field(strict=True)] = Field(
        default_factory=list
    )
    failure_reason: FailureReason | None = None

    def to_domain(self) -> ExpectedResult:
        """Return the expected-result domain object used by policy checks."""
        return ExpectedResult(
            terminal_result=TerminalResult(self.terminal_result),
            media_count=self.media_count,
            media_kinds=tuple(self.media_kinds),
            failure_reason=self.failure_reason,
        )


class _CasePolicyInput(_InputModel):
    """Validated JSON representation of one case-specific policy."""

    outcome: Outcome | None = None
    expected: _ExpectedResultInput | None = None
    acceptable: Annotated[list[_ExpectedResultInput], Field(strict=True)] = Field(
        default_factory=list
    )
    reason: _NonEmptyString | None = None

    @field_validator("expected", mode="before")
    @classmethod
    def expected_is_not_null(cls, expected: object) -> object:
        """Distinguish an omitted expectation from an invalid explicit null."""
        if expected is None:
            raise ValueError("must be an object")
        return expected

    def to_domain(self) -> CasePolicy:
        """Return the case-policy domain object used by profile selection."""
        return CasePolicy(
            outcome=self.outcome,
            expected=self.expected.to_domain() if self.expected is not None else None,
            acceptable=tuple(result.to_domain() for result in self.acceptable),
            reason=self.reason,
        )


class _ProfilePolicyInput(_InputModel):
    """Validated JSON representation of one profile's case overrides."""

    cases: Annotated[dict[_NonEmptyString, _CasePolicyInput], Field(strict=True)]


class ExpectationsInput(_InputModel):
    """Validated JSON representation of the versioned expectation policy."""

    schema_version: Literal[2]
    default_rejected: Annotated[list[_NonEmptyString], Field(strict=True)]
    profiles: Annotated[dict[Profile, _ProfilePolicyInput], Field(strict=True)]

    @field_validator("default_rejected")
    @classmethod
    def rejected_cases_are_unique(cls, case_ids: list[str]) -> list[str]:
        """Reject duplicate default-rejection entries."""
        if len(case_ids) != len(set(case_ids)):
            raise ValueError("contains duplicate case IDs")
        return case_ids

    @model_validator(mode="after")
    def has_default_profile(self) -> Self:
        """Require policy for the default runner profile."""
        if Profile.NO_GALLERY not in self.profiles:
            raise ValueError(f"profiles.{Profile.NO_GALLERY} must be an object")
        return self

    def to_domain(self) -> CorpusPolicy:
        """Return the immutable policy values consumed by the runner."""
        return CorpusPolicy(
            default_rejected=frozenset(self.default_rejected),
            profiles={
                profile: {
                    case_id: case_policy.to_domain()
                    for case_id, case_policy in profile_policy.cases.items()
                }
                for profile, profile_policy in self.profiles.items()
            },
        )


def harness_validation_error(context: str, error: ValidationError) -> HarnessError:
    """Translate structured schema failures into harness-facing diagnostics."""
    messages = []
    for detail in error.errors(
        include_url=False, include_context=False, include_input=False
    ):
        location = _validation_location(detail["loc"])
        messages.append(f"{context}{location}: {detail['msg']}")
    return HarnessError("; ".join(messages))


def _validation_location(location: tuple[int | str, ...]) -> str:
    """Render one Pydantic location as a compact JSON-style path."""
    result = ""
    for component in location:
        if isinstance(component, int):
            result += f"[{component}]"
        else:
            result += f".{component}"
    return result
