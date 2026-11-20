// SPDX-License-Identifier: GPL-2.0-only
// Generated with linux-mdss-dsi-panel-driver-generator (--dumb-dcs) from the
// OnePlus Nord N100 vendor device tree (qcom,mdss_dsi_ili9882n_90hz_video),
// then edited: compatible, initial backlight level. Source material:
//   Copyright (c) 2013, The Linux Foundation. All rights reserved.
//
// No supply handling: on this phone the panel's LCDB rails (PMI632) have no
// mainline driver; the bootloader leaves them on (see the board DT).

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/device-id/of.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>

#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>
#include <drm/drm_probe_helper.h>

struct ili9882n_90hz {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct gpio_desc *reset_gpio;
};

static inline struct ili9882n_90hz *to_ili9882n_90hz(struct drm_panel *panel)
{
	return container_of_const(panel, struct ili9882n_90hz, panel);
}

static void ili9882n_90hz_reset(struct ili9882n_90hz *ctx)
{
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(10000, 11000);
}

static int ili9882n_90hz_on(struct ili9882n_90hz *ctx)
{
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };

	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xff, 0x98, 0x82, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x83, 0x30);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x84, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x88, 0xe2);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x89, 0xea);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x8a, 0xf6);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x8b, 0xf6);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x8c, 0xbf);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x8d, 0xc5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x8e, 0xcb);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x8f, 0xd1);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x90, 0xd7);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x91, 0xdd);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x92, 0xe3);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x93, 0xe9);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x94, 0xf6);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x95, 0xf6);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xff, 0x98, 0x82, 0x06);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x48, 0x05);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x4d, 0x80);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x4e, 0x40);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xc7, 0x05);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xff, 0x98, 0x82, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x35, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x53, 0x24);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x55, 0x01);
	mipi_dsi_dcs_exit_sleep_mode_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 120);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xff, 0x98, 0x82, 0x01);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x05, 0x33);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x07, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xff, 0x98, 0x82, 0x02);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x06, 0x57);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x0d, 0x1c);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x0e, 0x7b);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xff, 0x98, 0x82, 0x0b);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x9b, 0xce);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x9e, 0x46);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0x9f, 0x46);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xff, 0x98, 0x82, 0x00);
	mipi_dsi_dcs_set_display_on_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 20);

	return dsi_ctx.accum_err;
}

static int ili9882n_90hz_off(struct ili9882n_90hz *ctx)
{
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };

	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xff, 0x98, 0x82, 0x00);
	mipi_dsi_dcs_set_display_off_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 20);
	mipi_dsi_dcs_enter_sleep_mode_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 120);

	return dsi_ctx.accum_err;
}

static int ili9882n_90hz_prepare(struct drm_panel *panel)
{
	struct ili9882n_90hz *ctx = to_ili9882n_90hz(panel);
	struct device *dev = &ctx->dsi->dev;
	int ret;

	ili9882n_90hz_reset(ctx);

	ret = ili9882n_90hz_on(ctx);
	if (ret < 0) {
		dev_err(dev, "Failed to initialize panel: %d\n", ret);
		gpiod_set_value_cansleep(ctx->reset_gpio, 1);
		return ret;
	}

	return 0;
}

static int ili9882n_90hz_unprepare(struct drm_panel *panel)
{
	struct ili9882n_90hz *ctx = to_ili9882n_90hz(panel);
	struct device *dev = &ctx->dsi->dev;
	int ret;

	ret = ili9882n_90hz_off(ctx);
	if (ret < 0)
		dev_err(dev, "Failed to un-initialize panel: %d\n", ret);

	gpiod_set_value_cansleep(ctx->reset_gpio, 1);

	return 0;
}

static const struct drm_display_mode ili9882n_90hz_mode = {
	.clock = (720 + 28 + 8 + 28) * (1600 + 1348 + 2 + 18) * 60 / 1000,
	.hdisplay = 720,
	.hsync_start = 720 + 28,
	.hsync_end = 720 + 28 + 8,
	.htotal = 720 + 28 + 8 + 28,
	.vdisplay = 1600,
	.vsync_start = 1600 + 1348,
	.vsync_end = 1600 + 1348 + 2,
	.vtotal = 1600 + 1348 + 2 + 18,
	.width_mm = 68,
	.height_mm = 151,
	.type = DRM_MODE_TYPE_DRIVER,
};

static int ili9882n_90hz_get_modes(struct drm_panel *panel,
				   struct drm_connector *connector)
{
	return drm_connector_helper_get_modes_fixed(connector, &ili9882n_90hz_mode);
}

static const struct drm_panel_funcs ili9882n_90hz_panel_funcs = {
	.prepare = ili9882n_90hz_prepare,
	.unprepare = ili9882n_90hz_unprepare,
	.get_modes = ili9882n_90hz_get_modes,
};

static int ili9882n_90hz_bl_update_status(struct backlight_device *bl)
{
	struct mipi_dsi_device *dsi = bl_get_data(bl);
	u16 brightness = backlight_get_brightness(bl);
	int ret;

	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;

	ret = mipi_dsi_dcs_set_display_brightness_large(dsi, brightness);
	if (ret < 0)
		return ret;

	dsi->mode_flags |= MIPI_DSI_MODE_LPM;

	return 0;
}

// TODO: Check if /sys/class/backlight/.../actual_brightness actually returns
// correct values. If not, remove this function.
static int ili9882n_90hz_bl_get_brightness(struct backlight_device *bl)
{
	struct mipi_dsi_device *dsi = bl_get_data(bl);
	u16 brightness;
	int ret;

	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;

	ret = mipi_dsi_dcs_get_display_brightness_large(dsi, &brightness);
	if (ret < 0)
		return ret;

	dsi->mode_flags |= MIPI_DSI_MODE_LPM;

	return brightness;
}

static const struct backlight_ops ili9882n_90hz_bl_ops = {
	.update_status = ili9882n_90hz_bl_update_status,
	.get_brightness = ili9882n_90hz_bl_get_brightness,
};

static struct backlight_device *
ili9882n_90hz_create_backlight(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	const struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		/* Vendor default level (qcom,mdss-dsi-bl-default-level absent; 0x159
		 * is the vendor's boot level). Max is the vendor's 11-bit 0x7ff. */
		.brightness = 345,
		.max_brightness = 2047,
	};

	return devm_backlight_device_register(dev, dev_name(dev), dev, dsi,
					      &ili9882n_90hz_bl_ops, &props);
}

static int ili9882n_90hz_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct ili9882n_90hz *ctx;
	int ret;

	ctx = devm_drm_panel_alloc(dev, struct ili9882n_90hz, panel,
				   &ili9882n_90hz_panel_funcs,
				   DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio),
				     "Failed to get reset-gpios\n");

	ctx->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_MODE_VIDEO | MIPI_DSI_CLOCK_NON_CONTINUOUS |
			  MIPI_DSI_MODE_LPM;

	ctx->panel.prepare_prev_first = true;

	ctx->panel.backlight = ili9882n_90hz_create_backlight(dsi);
	if (IS_ERR(ctx->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(ctx->panel.backlight),
				     "Failed to create backlight\n");

	ret = devm_drm_panel_add(dev, &ctx->panel);
	if (ret)
		return ret;

	return devm_mipi_dsi_attach(dev, dsi);
}

static const struct of_device_id ili9882n_90hz_of_match[] = {
	{ .compatible = "oneplus,billie2-ili9882n" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ili9882n_90hz_of_match);

static struct mipi_dsi_driver ili9882n_90hz_driver = {
	.probe = ili9882n_90hz_probe,
	.driver = {
		.name = "panel-ili9882n-90hz",
		.of_match_table = ili9882n_90hz_of_match,
	},
};
module_mipi_dsi_driver(ili9882n_90hz_driver);

MODULE_AUTHOR("fedora-atomic-phone (generated by linux-mdss-dsi-panel-driver-generator)");
MODULE_DESCRIPTION("DRM driver for ili9882n 90hz fhd video mode dsi panel");
MODULE_LICENSE("GPL");
