//go:build unit

package service

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/stretchr/testify/require"
)

func floatPtr(v float64) *float64 {
	return &v
}

func TestEffectiveUserBillingMultiplier(t *testing.T) {
	tests := []struct {
		name string
		cfg  *config.Config
		base float64
		want float64
	}{
		{
			name: "nil config uses base multiplier",
			base: 1.25,
			want: 1.25,
		},
		{
			name: "unset global multiplier keeps compatibility",
			cfg:  &config.Config{},
			base: 1.25,
			want: 1.25,
		},
		{
			name: "global multiplier is applied after base multiplier",
			cfg:  &config.Config{Default: config.DefaultConfig{UserBillingMultiplier: floatPtr(0.8)}},
			base: 1.25,
			want: 1.0,
		},
		{
			name: "explicit zero global multiplier disables user billing",
			cfg:  &config.Config{Default: config.DefaultConfig{UserBillingMultiplier: floatPtr(0)}},
			base: 1.25,
			want: 0,
		},
		{
			name: "negative base multiplier is clamped",
			cfg:  &config.Config{Default: config.DefaultConfig{UserBillingMultiplier: floatPtr(2)}},
			base: -1,
			want: 0,
		},
		{
			name: "negative global multiplier falls back to compatibility default",
			cfg:  &config.Config{Default: config.DefaultConfig{UserBillingMultiplier: floatPtr(-1)}},
			base: 1.25,
			want: 1.25,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.InDelta(t, tt.want, effectiveUserBillingMultiplier(tt.cfg, tt.base), 1e-12)
		})
	}
}

func TestEffectiveUserBillingMultiplierWithSettings(t *testing.T) {
	repo := newMockSettingRepo()
	raw, err := json.Marshal(UserBillingMultiplierSettings{
		Enabled:    true,
		Multiplier: 0.5,
	})
	require.NoError(t, err)
	repo.data[SettingKeyUserBillingMultiplierSettings] = string(raw)
	svc := NewSettingService(repo, &config.Config{
		Default: config.DefaultConfig{UserBillingMultiplier: floatPtr(0.8)},
	})

	got := effectiveUserBillingMultiplierWithSettings(context.Background(), svc.cfg, svc, 2)

	require.InDelta(t, 1.0, got, 1e-12)
}

func TestEffectiveUserBillingMultiplierWithSettings_Disabled(t *testing.T) {
	repo := newMockSettingRepo()
	raw, err := json.Marshal(UserBillingMultiplierSettings{
		Enabled:    false,
		Multiplier: 0.5,
	})
	require.NoError(t, err)
	repo.data[SettingKeyUserBillingMultiplierSettings] = string(raw)
	svc := NewSettingService(repo, &config.Config{
		Default: config.DefaultConfig{UserBillingMultiplier: floatPtr(0.8)},
	})

	got := effectiveUserBillingMultiplierWithSettings(context.Background(), svc.cfg, svc, 2)

	require.InDelta(t, 2.0, got, 1e-12)
}

type userBillingCtxAwareRepo struct {
	value string
	calls int
}

func (r *userBillingCtxAwareRepo) Get(ctx context.Context, key string) (*Setting, error) {
	value, err := r.GetValue(ctx, key)
	if err != nil {
		return nil, err
	}
	return &Setting{Key: key, Value: value}, nil
}

func (r *userBillingCtxAwareRepo) GetValue(ctx context.Context, _ string) (string, error) {
	r.calls++
	if err := ctx.Err(); err != nil {
		return "", err
	}
	return r.value, nil
}

func (r *userBillingCtxAwareRepo) Set(context.Context, string, string) error { return nil }

func (r *userBillingCtxAwareRepo) GetMultiple(context.Context, []string) (map[string]string, error) {
	return map[string]string{}, nil
}

func (r *userBillingCtxAwareRepo) SetMultiple(context.Context, map[string]string) error { return nil }

func (r *userBillingCtxAwareRepo) GetAll(context.Context) (map[string]string, error) {
	return map[string]string{}, nil
}

func (r *userBillingCtxAwareRepo) Delete(context.Context, string) error { return nil }

func TestEffectiveUserBillingMultipliersWithSettings_DetachesCanceledContextAndReadsOnce(t *testing.T) {
	raw, err := json.Marshal(UserBillingMultiplierSettings{
		Enabled:    true,
		Multiplier: 0.5,
	})
	require.NoError(t, err)
	repo := &userBillingCtxAwareRepo{value: string(raw)}
	svc := NewSettingService(repo, &config.Config{
		Default: config.DefaultConfig{UserBillingMultiplier: floatPtr(0.8)},
	})

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	multiplier, imageMultiplier := effectiveUserBillingMultipliersWithSettings(ctx, svc.cfg, svc, 2, 3)

	require.InDelta(t, 1.0, multiplier, 1e-12)
	require.InDelta(t, 1.5, imageMultiplier, 1e-12)
	require.Equal(t, 1, repo.calls)
}
