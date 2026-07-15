# services/meeting-api/tests/test_auto_leave_contracts.py
"""Contracts for auto-leave: silence + everyone-left (SPEC-AUTO-LEAVE-SILENCE-EMPTY).

TDD: these must fail before implementation, then pass after T1 greens.
"""

from datetime import datetime
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from meeting_api.schemas import (
    AutomaticLeave,
    MeetingCompletionReason,
    MeetingStatus,
)
from meeting_api.callbacks import _classify_stopped_exit
from .conftest import make_meeting, MockResult


class TestInactiveNoAudioClassifier:
    @pytest.mark.asyncio
    async def test_inactive_no_audio_routes_completed(self, mock_db):
        """INACTIVE_NO_AUDIO is a legitimate end-of-meeting; routes to COMPLETED."""
        meeting = make_meeting(status=MeetingStatus.ACTIVE.value)
        target_status, returned_reason = await _classify_stopped_exit(
            meeting, mock_db, MeetingCompletionReason.INACTIVE_NO_AUDIO,
        )
        assert target_status == MeetingStatus.COMPLETED
        assert returned_reason == MeetingCompletionReason.INACTIVE_NO_AUDIO

    def test_inactive_no_audio_enum_value(self):
        assert MeetingCompletionReason.INACTIVE_NO_AUDIO.value == "inactive_no_audio"


class TestCompletionMessages:
    def test_left_alone_message(self):
        from meeting_api.schemas import completion_message_for

        assert completion_message_for(MeetingCompletionReason.LEFT_ALONE) == (
            "All participants have left the meeting"
        )

    def test_inactive_no_audio_message(self):
        from meeting_api.schemas import completion_message_for

        assert completion_message_for(MeetingCompletionReason.INACTIVE_NO_AUDIO) == (
            "Meeting inactive — no audio activity"
        )

    def test_unknown_reason_returns_none(self):
        from meeting_api.schemas import completion_message_for

        assert completion_message_for(MeetingCompletionReason.STOPPED) is None


class TestAutomaticLeaveSilenceField:
    def test_accepts_no_audio_activity_timeout(self):
        leave = AutomaticLeave(no_audio_activity_timeout=60_000)
        assert leave.no_audio_activity_timeout == 60_000

    def test_forbids_unknown_keys(self):
        with pytest.raises(ValidationError):
            AutomaticLeave(silence_timeout_typo=123)


class TestAutomaticLeaveDefaults:
    def test_roosterx_defaults(self):
        from meeting_api.schemas import AUTOMATIC_LEAVE_DEFAULTS_MS

        assert AUTOMATIC_LEAVE_DEFAULTS_MS["max_time_left_alone"] == 600_000
        assert AUTOMATIC_LEAVE_DEFAULTS_MS["no_audio_activity_timeout"] == 600_000
        assert AUTOMATIC_LEAVE_DEFAULTS_MS["no_one_joined_timeout"] == 600_000
