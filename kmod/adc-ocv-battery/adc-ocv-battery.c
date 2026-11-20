// SPDX-License-Identifier: GPL-2.0-only
/*
 * Battery state from ADC readings only: voltage from an IIO channel, capacity
 * from the monitored battery's OCV table, charging guessed from USB input
 * voltage. Read-only: it never touches a charger. A stopgap for PMICs whose
 * fuel gauge has no mainline driver (e.g. PMI632 QGauge on the N100).
 *
 * The capacity is approximate: under load or while charging the measured
 * voltage differs from the open-circuit voltage the table describes.
 */
#include <linux/iio/consumer.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/property.h>

/* USB input above this counts as a charger being present. */
#define USBIN_PRESENT_UV	4000000

struct adc_ocv_battery {
	struct power_supply *psy;
	struct power_supply_battery_info *info;
	struct iio_channel *vbat;
	struct iio_channel *usbin;	/* optional */
};

static const enum power_supply_property adc_ocv_battery_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_VOLTAGE_MAX_DESIGN,
	POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN,
	POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
	POWER_SUPPLY_PROP_CAPACITY,
};

static int adc_ocv_battery_capacity(struct adc_ocv_battery *bat, int *cap)
{
	int uv, ret;

	ret = iio_read_channel_processed(bat->vbat, &uv);
	if (ret < 0)
		return ret;
	/* Tables are per temperature; without a battery thermistor use 25 C. */
	*cap = power_supply_batinfo_ocv2cap(bat->info, uv, 25);
	return *cap < 0 ? *cap : 0;
}

static bool adc_ocv_battery_usb_present(struct adc_ocv_battery *bat)
{
	int uv;

	if (!bat->usbin || iio_read_channel_processed(bat->usbin, &uv) < 0)
		return false;
	return uv > USBIN_PRESENT_UV;
}

static int adc_ocv_battery_get_property(struct power_supply *psy,
					enum power_supply_property psp,
					union power_supply_propval *val)
{
	struct adc_ocv_battery *bat = power_supply_get_drvdata(psy);
	int ret, cap;

	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
		if (!adc_ocv_battery_usb_present(bat)) {
			val->intval = POWER_SUPPLY_STATUS_DISCHARGING;
			return 0;
		}
		ret = adc_ocv_battery_capacity(bat, &cap);
		if (ret)
			return ret;
		val->intval = cap >= 100 ? POWER_SUPPLY_STATUS_FULL :
					   POWER_SUPPLY_STATUS_CHARGING;
		return 0;
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = 1;
		return 0;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = bat->info->technology;
		return 0;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		return iio_read_channel_processed(bat->vbat, &val->intval);
	case POWER_SUPPLY_PROP_VOLTAGE_MAX_DESIGN:
		val->intval = bat->info->voltage_max_design_uv;
		return val->intval < 0 ? -ENODATA : 0;
	case POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN:
		val->intval = bat->info->voltage_min_design_uv;
		return val->intval < 0 ? -ENODATA : 0;
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
		val->intval = bat->info->charge_full_design_uah;
		return val->intval < 0 ? -ENODATA : 0;
	case POWER_SUPPLY_PROP_CAPACITY:
		return adc_ocv_battery_capacity(bat, &val->intval);
	default:
		return -EINVAL;
	}
}

static const struct power_supply_desc adc_ocv_battery_desc = {
	.name = "battery",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = adc_ocv_battery_props,
	.num_properties = ARRAY_SIZE(adc_ocv_battery_props),
	.get_property = adc_ocv_battery_get_property,
};

static int adc_ocv_battery_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct power_supply_config cfg = {};
	struct adc_ocv_battery *bat;
	int ret;

	bat = devm_kzalloc(dev, sizeof(*bat), GFP_KERNEL);
	if (!bat)
		return -ENOMEM;

	bat->vbat = devm_iio_channel_get(dev, "vbat");
	if (IS_ERR(bat->vbat))
		return dev_err_probe(dev, PTR_ERR(bat->vbat), "no vbat channel\n");

	bat->usbin = devm_iio_channel_get(dev, "usbin");
	if (IS_ERR(bat->usbin)) {
		if (PTR_ERR(bat->usbin) == -EPROBE_DEFER)
			return -EPROBE_DEFER;
		bat->usbin = NULL;
	}

	cfg.fwnode = dev_fwnode(dev);
	cfg.drv_data = bat;
	bat->psy = devm_power_supply_register(dev, &adc_ocv_battery_desc, &cfg);
	if (IS_ERR(bat->psy))
		return dev_err_probe(dev, PTR_ERR(bat->psy), "register failed\n");

	ret = power_supply_get_battery_info(bat->psy, &bat->info);
	if (ret)
		return dev_err_probe(dev, ret, "no monitored-battery\n");
	if (!bat->info->ocv_table_size[0])
		return dev_err_probe(dev, -EINVAL, "monitored-battery has no OCV table\n");

	return 0;
}

static const struct of_device_id adc_ocv_battery_of_match[] = {
	{ .compatible = "fap,adc-ocv-battery" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, adc_ocv_battery_of_match);

static struct platform_driver adc_ocv_battery_driver = {
	.probe = adc_ocv_battery_probe,
	.driver = {
		.name = "adc-ocv-battery",
		.of_match_table = adc_ocv_battery_of_match,
	},
};
module_platform_driver(adc_ocv_battery_driver);

MODULE_DESCRIPTION("Battery capacity from ADC voltage and an OCV table");
MODULE_AUTHOR("fedora-atomic-phone");
MODULE_LICENSE("GPL");
MODULE_IMPORT_NS("IIO_CONSUMER");
