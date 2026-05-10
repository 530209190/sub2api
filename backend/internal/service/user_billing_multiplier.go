package service

import (
	"context"
	"math"

	"github.com/Wei-Shaw/sub2api/internal/config"
)

func normalizeUserBillingMultiplierValue(value, fallback float64) float64 {
	if math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
		return fallback
	}
	return value
}

func normalizeBaseUserBillingMultiplier(baseMultiplier float64) float64 {
	return normalizeUserBillingMultiplierValue(baseMultiplier, 0)
}

func defaultUserBillingMultiplierFromConfig(cfg *config.Config) float64 {
	if cfg == nil {
		return 1
	}
	globalMultiplier := 1.0
	if cfg.Default.UserBillingMultiplier != nil {
		globalMultiplier = normalizeUserBillingMultiplierValue(*cfg.Default.UserBillingMultiplier, 1)
	}
	return globalMultiplier
}

func effectiveUserBillingMultiplier(cfg *config.Config, baseMultiplier float64) float64 {
	baseMultiplier = normalizeBaseUserBillingMultiplier(baseMultiplier)
	return baseMultiplier * defaultUserBillingMultiplierFromConfig(cfg)
}

func effectiveUserBillingMultiplierWithSettings(ctx context.Context, cfg *config.Config, settingService *SettingService, baseMultiplier float64) float64 {
	baseMultiplier = normalizeBaseUserBillingMultiplier(baseMultiplier)
	if settingService == nil {
		return effectiveUserBillingMultiplier(cfg, baseMultiplier)
	}

	settings, err := settingService.GetUserBillingMultiplierSettings(ctx)
	if err != nil || settings == nil {
		return effectiveUserBillingMultiplier(cfg, baseMultiplier)
	}
	if !settings.Enabled {
		return baseMultiplier
	}

	return baseMultiplier * normalizeUserBillingMultiplierValue(settings.Multiplier, defaultUserBillingMultiplierFromConfig(cfg))
}

func applyUserBillingMultiplierSettings(cfg *config.Config, settings *UserBillingMultiplierSettings, baseMultiplier float64) float64 {
	baseMultiplier = normalizeBaseUserBillingMultiplier(baseMultiplier)
	if settings == nil {
		return effectiveUserBillingMultiplier(cfg, baseMultiplier)
	}
	if !settings.Enabled {
		return baseMultiplier
	}
	return baseMultiplier * normalizeUserBillingMultiplierValue(settings.Multiplier, defaultUserBillingMultiplierFromConfig(cfg))
}

func resolveUserBillingMultiplierSettingsForBilling(ctx context.Context, cfg *config.Config, settingService *SettingService) *UserBillingMultiplierSettings {
	if settingService == nil {
		return DefaultUserBillingMultiplierSettings(cfg)
	}

	billingCtx, cancel := detachedBillingContext(ctx)
	defer cancel()

	settings, err := settingService.GetUserBillingMultiplierSettings(billingCtx)
	if err != nil || settings == nil {
		return DefaultUserBillingMultiplierSettings(cfg)
	}
	return settings
}

func effectiveUserBillingMultipliersWithSettings(ctx context.Context, cfg *config.Config, settingService *SettingService, baseMultiplier, imageBaseMultiplier float64) (float64, float64) {
	settings := resolveUserBillingMultiplierSettingsForBilling(ctx, cfg, settingService)
	return applyUserBillingMultiplierSettings(cfg, settings, baseMultiplier),
		applyUserBillingMultiplierSettings(cfg, settings, imageBaseMultiplier)
}

func DefaultUserBillingMultiplierSettings(cfg *config.Config) *UserBillingMultiplierSettings {
	return &UserBillingMultiplierSettings{
		Enabled:    true,
		Multiplier: defaultUserBillingMultiplierFromConfig(cfg),
	}
}
