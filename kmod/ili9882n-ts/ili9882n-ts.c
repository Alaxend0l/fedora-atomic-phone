// SPDX-License-Identifier: GPL-2.0-only
/*
 * Ilitek ILI9882N TDDI touchscreen over SPI.
 *
 * The controller has no flash: the host uploads the firmware into its IRAM
 * after every reset ("host download"), then the firmware streams 43-byte
 * demo-mode reports on each interrupt. Protocol from the OnePlus Nord N100
 * GPL kernel (drivers/input/touchscreen/oneplus_touchscreen/ilitek/
 * ilitek9882n, Ilitek driver 3.0.2.0), reimplemented minimally: firmware
 * upload, multitouch reports. No gestures, MP tests or proc nodes.
 *
 * Firmware: an "ILI" image (256-byte header + payload), e.g. the vendor's
 * FW_20221_ILI9882N_TXD array, via request_firmware(firmware-name).
 *
 * Ordering matters on this in-cell panel: the firmware must be uploaded after
 * the display has been powered on and initialised, without pulsing the touch
 * reset pin (the panel's reset already reset the chip). Uploading earlier, or
 * after a touch reset, gives a running firmware that never reports touches.
 * So with a "panel" phandle the driver is a DRM panel follower and uploads
 * shortly after panel_prepared(), like the vendor's lcd_trigger_load_tp_fw
 * path. "Shortly after": the touch scan is clocked by the display timing, so
 * the DSI video stream (started after prepare, at enable) must be running;
 * the follower API has no enable hook, hence a delayed work item.
 */
#include <drm/drm_panel.h>
#include <linux/crc32.h>
#include <linux/delay.h>
#include <linux/devm-helpers.h>
#include <linux/firmware.h>
#include <linux/gpio/consumer.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/input/touchscreen.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mod_devicetable.h>
#include <linux/spi/spi.h>
#include <linux/unaligned.h>
#include <linux/workqueue.h>

#define ILI_SPI_WRITE		0x82
#define ILI_SPI_READ		0x83
#define ILI_SPI_ACK		0xa3

#define ILI_ICE_ENTER		0x25
#define ILI_ICE_EXIT		0x1b
#define ILI_ICE_REG		0x25

#define ILI_REG_DUMMY		0x51024
#define ILI_REG_PID		0x4009c
#define ILI_REG_CODE_RESET	0x40040
#define ILI_CODE_RESET_KEY	0xae

/* DMA CRC engine, used to verify each uploaded block. */
#define ILI_REG_DMA1_CTRL	0x72100
#define ILI_REG_DMA1_SRC	0x72104
#define ILI_REG_DMA1_SRC_FMT	0x72108
#define ILI_REG_DMA1_DST	0x72114
#define ILI_REG_DMA1_DST_FMT	0x72118
#define ILI_REG_DMA1_SIZE	0x7211c
#define ILI_REG_CRC_ON		0x41016
#define ILI_REG_CRC_DMA		0x41017
#define ILI_REG_CRC_RESULT	0x4101c
#define ILI_REG_INT_FLAG	0x48006

#define ILI_FILE_HEADER		256
#define ILI_MAX_FW_SIZE		(160 * 1024)
#define ILI_BLOCKS		17
#define ILI_BLK_AP		1
#define ILI_BLK_DATA		2
#define ILI_BLK_TUNING		3
#define ILI_DLM_START		0x20610
#define ILI_UPLOAD_CHUNK	2048

#define ILI_PACKET_LEN		43
#define ILI_PACKET_DEMO		0x5a
#define ILI_PACKET_INFO_HDR	0xb7
#define ILI_INFO_HDR_LEN	3
#define ILI_MAX_FINGERS		10
#define ILI_RAW_MAX		2047	/* firmware reports 0..2047 on both axes */

static bool hw_reset = true;
module_param(hw_reset, bool, 0444);
MODULE_PARM_DESC(hw_reset, "Pulse the touch reset pin before upload (0: rely on the panel's reset, as the vendor does when the LCD triggers the load)");

struct ili_block {
	u32 start;	/* offset in the payload */
	u32 len;
	u32 mem;	/* IRAM address */
	bool fixed;
};

struct ili9882n {
	struct spi_device *spi;
	struct input_dev *input;
	struct gpio_desc *reset;
	struct touchscreen_properties prop;
	const char *fw_name;
	const struct firmware *fw;
	struct drm_panel_follower follower;
	struct delayed_work upload_work;
	bool irq_on;	/* enabled by a successful follower upload */
	bool ice;
	u8 *tx;		/* DMA-safe transfer buffers */
	u8 *rx;
};

static int ili_xfer(struct ili9882n *ts, const u8 *tx, u8 *rx, size_t len)
{
	struct spi_transfer t = {
		.tx_buf = tx,
		.rx_buf = rx,
		.len = len,
	};

	return spi_sync_transfer(ts->spi, &t, 1);
}

/* Write: 0x82 + payload in ICE mode, 0x82 len_hi len_lo + payload otherwise. */
static int ili_write(struct ili9882n *ts, const u8 *buf, size_t len)
{
	size_t hdr = ts->ice ? 1 : 3;

	if (len + hdr > ILI_UPLOAD_CHUNK + 8)
		return -EINVAL;
	ts->tx[0] = ILI_SPI_WRITE;
	if (!ts->ice) {
		ts->tx[1] = len >> 8;
		ts->tx[2] = len & 0xff;
	}
	memcpy(ts->tx + hdr, buf, len);
	return ili_xfer(ts, ts->tx, NULL, len + hdr);
}

/*
 * Read: one full-duplex transfer starting with 0x83. Outside ICE mode the
 * controller answers with two extra bytes, the second being an ACK (0xa3).
 */
static int ili_read(struct ili9882n *ts, u8 *buf, size_t len)
{
	size_t skip = ts->ice ? 1 : 3;
	int ret;

	if (len + skip > ILI_UPLOAD_CHUNK + 8)
		return -EINVAL;
	memset(ts->tx, 0, len + skip);
	ts->tx[0] = ILI_SPI_READ;
	ret = ili_xfer(ts, ts->tx, ts->rx, len + skip);
	if (ret)
		return ret;
	if (!ts->ice && ts->rx[1] != ILI_SPI_ACK)
		return -EIO;
	memcpy(buf, ts->rx + skip, len);
	return 0;
}

static int ili_ice(struct ili9882n *ts, bool enable)
{
	u8 cmd[4] = { enable ? ILI_ICE_ENTER : ILI_ICE_EXIT, 0x62, 0x10, 0x18 };
	int ret;

	/* The enter command itself is already framed the ICE way. */
	ts->ice = true;
	ret = ili_write(ts, cmd, sizeof(cmd));
	ts->ice = enable ? !ret : false;
	return ret;
}

static int ili_ice_write(struct ili9882n *ts, u32 addr, u32 val, int len)
{
	u8 buf[8] = { ILI_ICE_REG, addr, addr >> 8, addr >> 16 };
	int i;

	for (i = 0; i < len; i++)
		buf[4 + i] = val >> (8 * i);
	return ili_write(ts, buf, 4 + len);
}

static int ili_ice_read(struct ili9882n *ts, u32 addr, u32 *val, int len)
{
	u8 cmd[4] = { ILI_ICE_REG, addr, addr >> 8, addr >> 16 };
	u8 buf[4] = {};
	int ret;

	ret = ili_write(ts, cmd, sizeof(cmd));
	if (!ret)
		ret = ili_read(ts, buf, len);
	if (!ret)
		*val = len == 1 ? buf[0] : get_unaligned_le32(buf);
	return ret;
}

/*
 * After leaving ICE mode the vendor driver precedes the next command with a
 * dummy write of 0xa3 bytes to wake the controller's SPI PLL clock.
 */
static int ili_pll_wakeup(struct ili9882n *ts)
{
	static const u8 wake[9] = { [0 ... 8] = ILI_SPI_ACK };

	return ili_write(ts, wake, sizeof(wake));
}

/* Firmware command with a reply: 0xf6 <cmd>, then <cmd>, then read. */
static int ili_cmd_read(struct ili9882n *ts, u8 cmd, u8 *buf, size_t len)
{
	u8 pre[2] = { 0xf6, cmd };
	int ret;

	ret = ili_write(ts, pre, sizeof(pre));
	if (!ret)
		ret = ili_write(ts, &cmd, 1);
	if (ret)
		return ret;
	msleep(20);	/* the firmware pulses INT when the reply is ready */
	ret = ili_read(ts, buf, len);
	if (!ret && buf[0] != cmd)
		ret = -EIO;
	return ret;
}

static void ili_hw_reset(struct ili9882n *ts)
{
	/* Vendor timing: high 1 ms, low 5 ms, high, then 10 ms. */
	gpiod_set_value_cansleep(ts->reset, 0);
	usleep_range(1000, 1100);
	gpiod_set_value_cansleep(ts->reset, 1);
	usleep_range(5000, 5100);
	gpiod_set_value_cansleep(ts->reset, 0);
	usleep_range(10000, 10100);
	ts->ice = false;
}

/* CRC-32 (poly 0x04c11db7, MSB first, init ~0, no final xor) as the IC does. */
static u32 ili_crc32(const u8 *p, size_t len)
{
	return crc32_be(0xffffffff, p, len);
}

static int ili_dma_crc(struct ili9882n *ts, u32 mem, u32 len, u32 *crc)
{
	static const struct { u32 reg, val; int len; } seq[] = {
		{ ILI_REG_DMA1_SRC_FMT, 0x80000001, 4 },
		{ ILI_REG_DMA1_DST, 0x0002725c, 4 },
		{ ILI_REG_DMA1_DST_FMT, 0x80000000, 4 },
	};
	u32 flag = 0;
	int i, ret;

	ret = ili_ice_write(ts, ILI_REG_DMA1_SRC, mem, 4);
	for (i = 0; !ret && i < ARRAY_SIZE(seq); i++)
		ret = ili_ice_write(ts, seq[i].reg, seq[i].val, seq[i].len);
	if (!ret)
		ret = ili_ice_write(ts, ILI_REG_DMA1_SIZE, len, 4);
	if (!ret)
		ret = ili_ice_write(ts, ILI_REG_CRC_ON, 0x00, 1);
	if (!ret)
		ret = ili_ice_write(ts, ILI_REG_CRC_DMA, 0x03, 1);
	if (!ret)
		ret = ili_ice_write(ts, ILI_REG_DMA1_CTRL, 0x02000000, 4);	/* stop */
	if (!ret)
		ret = ili_ice_write(ts, ILI_REG_CRC_ON, 0x01, 1);
	if (!ret)
		ret = ili_ice_write(ts, ILI_REG_INT_FLAG, 0x02, 1);		/* clear */
	if (!ret)
		ret = ili_ice_write(ts, ILI_REG_DMA1_CTRL, 0x01000000, 4);	/* start */
	if (ret)
		return ret;

	for (i = 0; i < 50; i++) {
		usleep_range(1000, 1100);
		ret = ili_ice_read(ts, ILI_REG_INT_FLAG, &flag, 1);
		if (ret)
			return ret;
		if (flag & 0x02)
			return ili_ice_read(ts, ILI_REG_CRC_RESULT, crc, 4);
	}
	return -ETIMEDOUT;
}

static int ili_parse_blocks(struct device *dev, const struct firmware *fw,
			    struct ili_block *blk)
{
	const u8 *h = fw->data;
	size_t plen = fw->size - ILI_FILE_HEADER;
	unsigned int map, i, n;

	if (fw->size <= ILI_FILE_HEADER || fw->size > ILI_MAX_FW_SIZE)
		return -EINVAL;
	map = (h[129] << 8) | h[130];
	if (!h[131] || h[131] >= ILI_BLOCKS || !map)
		return -EINVAL;

	memset(blk, 0, sizeof(*blk) * (ILI_BLOCKS + 1));
	for (i = 0; i < ILI_BLOCKS; i++) {
		u32 addr = (h[4 + i * 4] << 16) | (h[5 + i * 4] << 8) | h[6 + i * 4];

		n = h[7 + i * 4];
		if (n && n <= ILI_BLOCKS && addr) {
			blk[n].mem = addr;
			blk[n].fixed = true;
		}
	}
	for (i = 0; i < ILI_BLOCKS; i++) {
		const u8 *p = h + 132 + i * 6;
		u32 start, end;

		if (!(map & BIT(i)))
			continue;
		start = (p[0] << 16) | (p[1] << 8) | p[2];
		end = (p[3] << 16) | (p[4] << 8) | p[5];
		if (end < start + 4 || end >= plen)
			return -EINVAL;
		blk[i + 1].start = start;
		blk[i + 1].len = end - start + 1;
	}
	if (!blk[ILI_BLK_DATA].fixed)
		blk[ILI_BLK_DATA].mem = ILI_DLM_START;
	if (!blk[ILI_BLK_TUNING].fixed)
		blk[ILI_BLK_TUNING].mem = blk[ILI_BLK_DATA].mem + blk[ILI_BLK_DATA].len;
	return 0;
}

static int ili_upload_block(struct ili9882n *ts, const u8 *data, const struct ili_block *b)
{
	u32 off, crc_file, crc_dma = 0;
	int ret;

	crc_file = ili_crc32(data + b->start, b->len - 4);
	if (crc_file != get_unaligned_be32(data + b->start + b->len - 4))
		return -EBADMSG;

	for (off = 0; off < b->len; off += ILI_UPLOAD_CHUNK) {
		u32 addr = b->mem + off;
		u32 n = min_t(u32, ILI_UPLOAD_CHUNK, b->len - off);
		u8 *buf = ts->tx + 1;

		buf[0] = ILI_ICE_REG;
		buf[1] = addr;
		buf[2] = addr >> 8;
		buf[3] = addr >> 16;
		memcpy(buf + 4, data + b->start + off, n);
		/* Pad to a multiple of 4 with 0xff, as the vendor driver does. */
		while (n % 4)
			buf[4 + n++] = 0xff;
		ts->tx[0] = ILI_SPI_WRITE;
		ret = ili_xfer(ts, ts->tx, NULL, 1 + 4 + n);
		if (ret)
			return ret;
	}

	ret = ili_dma_crc(ts, b->mem, b->len - 4, &crc_dma);
	if (ret)
		return ret;
	if (crc_dma != crc_file) {
		dev_err(&ts->spi->dev, "block at %#x: CRC %#x, expected %#x\n",
			b->mem, crc_dma, crc_file);
		return -EIO;
	}
	return 0;
}

static int ili_load_firmware(struct ili9882n *ts, bool reset)
{
	struct device *dev = &ts->spi->dev;
	struct ili_block blk[ILI_BLOCKS + 1];
	static const int ap_blocks[] = { ILI_BLK_AP, ILI_BLK_DATA, ILI_BLK_TUNING };
	const struct firmware *fw = ts->fw;
	const u8 *data;
	u32 val = 0;
	int i, ret;

	ret = ili_parse_blocks(dev, fw, blk);
	if (ret) {
		dev_err(dev, "invalid ILI firmware image\n");
		return ret;
	}
	data = fw->data + ILI_FILE_HEADER;

	if (reset)
		ili_hw_reset(ts);
	ts->ice = false;
	ret = ili_ice(ts, true);
	if (ret)
		return ret;

	ret = ili_ice_write(ts, ILI_REG_DUMMY, 0xa55a5aa5, 4);
	if (!ret)
		ret = ili_ice_read(ts, ILI_REG_DUMMY, &val, 4);
	if (!ret && val != 0xa55a5aa5) {
		dev_err(dev, "SPI check failed: read %#x\n", val);
		ret = -ENODEV;
	}
	if (ret)
		goto out_reset;
	ret = ili_ice_read(ts, ILI_REG_PID, &val, 4);
	if (ret)
		goto out_reset;
	dev_info(dev, "chip PID %#x\n", val);
	if ((val >> 8) != 0x988217) {
		dev_err(dev, "not an ILI9882N\n");
		ret = -ENODEV;
		goto out_reset;
	}

	for (i = 0; i < ARRAY_SIZE(ap_blocks); i++) {
		const struct ili_block *b = &blk[ap_blocks[i]];

		if (!b->len)
			continue;
		ret = ili_upload_block(ts, data, b);
		if (ret) {
			dev_err(dev, "upload of block %d failed: %d\n", ap_blocks[i], ret);
			goto out_reset;
		}
	}

	/* Start the uploaded code, leave ICE mode, give it time to boot. */
	ret = ili_ice_write(ts, ILI_REG_CODE_RESET, ILI_CODE_RESET_KEY, 1);
	if (!ret)
		ret = ili_ice(ts, false);
	msleep(100);
	if (!ret)
		ret = ili_pll_wakeup(ts);
	if (!ret) {
		u8 ver[9] = {};
		int r = ili_cmd_read(ts, 0x21, ver, sizeof(ver));

		dev_info(dev, "firmware %s uploaded (file version %#x), chip reports %d: %*ph\n",
			 ts->fw_name,
			 get_unaligned_be32(data + blk[ILI_BLK_AP].start +
					    blk[ILI_BLK_AP].len - 1 - 0x4f + 48),
			 r, (int)sizeof(ver), ver);
		return 0;
	}

out_reset:
	ili_hw_reset(ts);
	return ret;
}

static u8 ili_checksum(const u8 *p, size_t len)
{
	u32 sum = 0;

	while (len--)
		sum += *p++;
	return -sum;
}

static irqreturn_t ili_irq(int irq, void *data)
{
	struct ili9882n *ts = data;
	u8 buf[ILI_PACKET_LEN];
	const u8 *p = buf;
	int i;

	struct device *dev = &ts->spi->dev;
	int ret;

	ret = ili_read(ts, buf, sizeof(buf));
	if (ret) {
		dev_err_ratelimited(dev, "report read failed: %d (ack byte %#x)\n",
				    ret, ts->rx[1]);
		return IRQ_HANDLED;
	}
	if (ili_checksum(buf, ILI_PACKET_LEN - 1) != buf[ILI_PACKET_LEN - 1]) {
		dev_err_ratelimited(dev, "report checksum mismatch: %*ph\n",
				    ILI_PACKET_LEN, buf);
		return IRQ_HANDLED;
	}
	if (p[0] == ILI_PACKET_INFO_HDR)
		p += ILI_INFO_HDR_LEN;
	if (p[0] != ILI_PACKET_DEMO) {
		dev_dbg_ratelimited(dev, "ignoring packet %#x\n", p[0]);
		return IRQ_HANDLED;
	}

	for (i = 0; i < ILI_MAX_FINGERS; i++) {
		const u8 *f = p + 1 + 4 * i;
		bool down = !(f[0] == 0xff && f[1] == 0xff && f[2] == 0xff);

		input_mt_slot(ts->input, i);
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, down);
		if (!down)
			continue;
		touchscreen_report_pos(ts->input, &ts->prop,
				       ((f[0] & 0xf0) << 4) | f[1],
				       ((f[0] & 0x0f) << 8) | f[2], true);
		input_report_abs(ts->input, ABS_MT_TOUCH_MAJOR, f[3]);
	}
	input_mt_sync_frame(ts->input);
	input_sync(ts->input);
	return IRQ_HANDLED;
}

/* Delay from panel prepare to upload, so the video stream is running. */
#define ILI_UPLOAD_DELAY_MS	200

static void ili_upload_work(struct work_struct *work)
{
	struct ili9882n *ts = container_of(to_delayed_work(work), struct ili9882n,
					   upload_work);

	if (!ili_load_firmware(ts, false)) {
		ts->irq_on = true;
		enable_irq(ts->spi->irq);
	}
}

static int ili_panel_prepared(struct drm_panel_follower *follower)
{
	struct ili9882n *ts = container_of(follower, struct ili9882n, follower);

	schedule_delayed_work(&ts->upload_work, msecs_to_jiffies(ILI_UPLOAD_DELAY_MS));
	return 0;
}

static int ili_panel_unpreparing(struct drm_panel_follower *follower)
{
	struct ili9882n *ts = container_of(follower, struct ili9882n, follower);

	cancel_delayed_work_sync(&ts->upload_work);
	if (ts->irq_on) {
		disable_irq(ts->spi->irq);
		ts->irq_on = false;
	}
	return 0;
}

static const struct drm_panel_follower_funcs ili_follower_funcs = {
	.panel_prepared = ili_panel_prepared,
	.panel_unpreparing = ili_panel_unpreparing,
};

static void ili_release_fw(void *fw)
{
	release_firmware(fw);
}

static int ili_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	struct ili9882n *ts;
	bool follower;
	int ret;

	ts = devm_kzalloc(dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;
	ts->spi = spi;
	ts->tx = devm_kzalloc(dev, ILI_UPLOAD_CHUNK + 16, GFP_KERNEL | GFP_DMA);
	ts->rx = devm_kzalloc(dev, ILI_UPLOAD_CHUNK + 16, GFP_KERNEL | GFP_DMA);
	if (!ts->tx || !ts->rx)
		return -ENOMEM;

	spi->mode = SPI_MODE_0;
	spi->bits_per_word = 8;
	ret = spi_setup(spi);
	if (ret)
		return ret;

	ts->reset = devm_gpiod_get(dev, "reset", GPIOD_ASIS);
	if (IS_ERR(ts->reset))
		return dev_err_probe(dev, PTR_ERR(ts->reset), "reset gpio\n");

	ts->fw_name = "ilitek/ili9882n.bin";
	device_property_read_string(dev, "firmware-name", &ts->fw_name);
	ret = request_firmware(&ts->fw, ts->fw_name, dev);
	if (ret)
		return dev_err_probe(dev, ret, "firmware %s\n", ts->fw_name);
	ret = devm_add_action_or_reset(dev, ili_release_fw, (void *)ts->fw);
	if (ret)
		return ret;

	ts->input = devm_input_allocate_device(dev);
	if (!ts->input)
		return -ENOMEM;
	ts->input->name = "ILI9882N Touchscreen";
	ts->input->id.bustype = BUS_SPI;
	input_set_abs_params(ts->input, ABS_MT_POSITION_X, 0, ILI_RAW_MAX, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_POSITION_Y, 0, ILI_RAW_MAX, 0, 0);
	input_set_abs_params(ts->input, ABS_MT_TOUCH_MAJOR, 0, 255, 0, 0);
	touchscreen_parse_properties(ts->input, true, &ts->prop);
	ret = input_mt_init_slots(ts->input, ILI_MAX_FINGERS,
				  INPUT_MT_DIRECT | INPUT_MT_DROP_UNUSED);
	if (ret)
		return ret;
	ret = input_register_device(ts->input);
	if (ret)
		return ret;

	follower = drm_is_panel_follower(dev);
	ret = devm_request_threaded_irq(dev, spi->irq, NULL, ili_irq,
					IRQF_ONESHOT | (follower ? IRQF_NO_AUTOEN : 0),
					dev_name(dev), ts);
	if (ret)
		return ret;

	if (follower) {
		ret = devm_delayed_work_autocancel(dev, &ts->upload_work, ili_upload_work);
		if (ret)
			return ret;
		ts->follower.funcs = &ili_follower_funcs;
		return devm_drm_panel_add_follower(dev, &ts->follower);
	}

	/* No panel link: upload now (works only if the panel is already set up). */
	disable_irq(spi->irq);
	ret = ili_load_firmware(ts, hw_reset);
	enable_irq(spi->irq);
	return ret;
}

static const struct of_device_id ili_of_match[] = {
	{ .compatible = "ilitek,ili9882n-ts" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ili_of_match);

static const struct spi_device_id ili_spi_ids[] = {
	{ "ili9882n-ts" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(spi, ili_spi_ids);

static struct spi_driver ili_driver = {
	.probe = ili_probe,
	.id_table = ili_spi_ids,
	.driver = {
		.name = "ili9882n-ts",
		.of_match_table = ili_of_match,
	},
};
module_spi_driver(ili_driver);

MODULE_DESCRIPTION("Ilitek ILI9882N TDDI SPI touchscreen");
MODULE_AUTHOR("fedora-atomic-phone");
MODULE_LICENSE("GPL");
