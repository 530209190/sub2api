package repository

import "testing"

func TestShouldEnqueueSchedulerOutboxForExtraUpdates_CompactCapabilityKeysAreRelevant(t *testing.T) {
	updates := map[string]any{
		"openai_compact_supported":  true,
		"openai_compact_checked_at": "2026-04-10T10:00:00Z",
	}

	if !shouldEnqueueSchedulerOutboxForExtraUpdates(updates) {
		t.Fatalf("expected compact capability updates to enqueue scheduler outbox")
	}
}

func TestShouldEnqueueSchedulerOutboxForExtraUpdates_ImageCapabilityKeysAreRelevant(t *testing.T) {
	updates := map[string]any{
		"supports_image_input": false,
	}

	if !shouldEnqueueSchedulerOutboxForExtraUpdates(updates) {
		t.Fatalf("expected image capability updates to enqueue scheduler outbox")
	}
}
