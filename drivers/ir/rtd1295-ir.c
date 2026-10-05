// SPDX-License-Identifier: GPL-2.0-only
/*
 * Realtek RTD1295/RTD1296 IR receiver
 *
 * The ISO block's IR unit has hardware decoders for a few protocols and a
 * raw mode; this driver uses only the raw mode, so that every protocol
 * rc-core decodes works. In raw mode the unit samples the receiver's
 * output every 40 us and packs 32 samples per word into a FIFO, earliest
 * sample in bit 31, 0 while the carrier is present (the receiver module's
 * output is active low). It interrupts when the FIFO holds fifo_thr words.
 *
 * Sampling starts at the first edge after the unit comes out of reset but
 * does not stop again: stop_time and stop_sample have no effect that could
 * be found (the stop bit does not even stick), nor does the soft reset or
 * toggling raw_en. So once rc-core has seen the frame end (idle), the
 * driver pulses the unit's reset and sets it up again, and the unit waits
 * for the next edge instead of interrupting 50 times a second.
 *
 * Register layout: Realtek's iso_reg.h; values: Realtek's BSP driver
 * (drivers/net/irda/realtek/rtk_irda.c, its software-decoder mode).
 */

#include <linux/bitfield.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/reset.h>
#include <linux/workqueue.h>
#include <media/rc-core.h>

#define DRIVER_NAME		"rtd1295-ir"

#define IR_SF			0x08	/* sampling clock divider */
#define IR_CR			0x10
#define  CR_SOFT_RESET		BIT(31)
#define  CR_RAW_OV_IE		BIT(14)
#define  CR_RAW_VAL_IE		BIT(13)
#define  CR_RAW_EN		BIT(12)
#define  CR_IRRES		BIT(9)
#define  CR_IRUE		BIT(8)	/* unit enable */
#define IR_SR			0x18
#define  SR_RAW_OV		BIT(3)
#define  SR_RAW_VAL		BIT(2)
#define IR_RAW_CTRL		0x1c
#define  RAW_WRITE_EN2		BIT(25)	/* stop_sample and stop_time */
#define  RAW_STOP_SAMPLE	BIT(24)
#define  RAW_STOP_TIME		GENMASK(23, 8)
#define  RAW_WRITE_EN1		BIT(6)	/* fifo_thr */
#define  RAW_FIFO_THR		GENMASK(5, 0)
#define IR_RAW_FF		0x20
#define IR_RAW_WL		0x28	/* words in the FIFO */
#define  RAW_WL_VAL		GENMASK(5, 0)
#define IR_RAW_DEB		0x2c
#define  RAW_DEB_CLK		GENMASK(15, 0)

#define IR_SAMPLE_US		40
#define IR_STOP_SAMPLES		5000	/* 200 ms after the last edge */
#define IR_FIFO_THR		16	/* words: 20 ms of samples */
#define IR_DEBOUNCE_NS		20000

struct rtd_ir {
	struct device *dev;
	void __iomem *base;
	struct rc_dev *rc;
	struct reset_control *rst;
	unsigned long rate;
	int irq;
	struct work_struct rearm;
	bool dying;
};

/*
 * One FIFO word: its runs of equal samples, earliest first. rc-core's
 * filter merges a run with the previous one of the same kind (runs cross
 * words and interrupts), and enters idle once a space reaches the timeout.
 */
static void rtd_ir_word(struct rtd_ir *ir, u32 word)
{
	struct ir_raw_event ev = {};
	int bit = 31;

	while (bit >= 0) {
		bool pulse = !(word & BIT(bit));
		int n = 0;

		while (bit >= 0 && !(word & BIT(bit)) == pulse) {
			bit--;
			n++;
		}
		ev.pulse = pulse;
		ev.duration = n * IR_SAMPLE_US;
		ir_raw_event_store_with_filter(ir->rc, &ev);
	}
}

static irqreturn_t rtd_ir_irq(int irq, void *data)
{
	struct rtd_ir *ir = data;
	u32 sr, n, i, edges;

	sr = readl(ir->base + IR_SR);
	if (!(sr & (SR_RAW_OV | SR_RAW_VAL)))
		return IRQ_NONE;
	/* as Realtek: the raw flags clear when the FIFO is read */
	writel(sr & ~0xf, ir->base + IR_SR);

	if (sr & SR_RAW_OV) {
		dev_dbg(ir->dev, "raw FIFO overflow\n");
		ir_raw_event_overflow(ir->rc);
	}

	n = FIELD_GET(RAW_WL_VAL, readl(ir->base + IR_RAW_WL));
	edges = 0;
	for (i = 0; i < n; i++) {
		u32 word = readl(ir->base + IR_RAW_FF);

		edges += word != U32_MAX;
		rtd_ir_word(ir, word);
	}
	dev_dbg(ir->dev, "SR %#x, %u words, %u not all space\n", sr, n, edges);

	ir_raw_event_handle(ir->rc);
	return IRQ_HANDLED;
}

static void rtd_ir_hw_init(struct rtd_ir *ir)
{
	unsigned long rate = ir->rate;

	writel(CR_SOFT_RESET, ir->base + IR_CR);
	writel(DIV_ROUND_CLOSEST(rate, 1000000) * IR_SAMPLE_US - 1,
	       ir->base + IR_SF);
	writel(FIELD_PREP(RAW_DEB_CLK,
			  DIV_ROUND_CLOSEST_ULL((u64)rate * IR_DEBOUNCE_NS,
						NSEC_PER_SEC) - 1),
	       ir->base + IR_RAW_DEB);
	writel(RAW_WRITE_EN2 | RAW_STOP_SAMPLE |
	       FIELD_PREP(RAW_STOP_TIME, IR_STOP_SAMPLES) |
	       RAW_WRITE_EN1 | FIELD_PREP(RAW_FIFO_THR, IR_FIFO_THR),
	       ir->base + IR_RAW_CTRL);
	writel(CR_RAW_OV_IE | CR_RAW_VAL_IE | CR_RAW_EN | CR_IRRES | CR_IRUE,
	       ir->base + IR_CR);
}

/* rc-core: the frame is over (a space of rc->timeout) */
static void rtd_ir_s_idle(struct rc_dev *rc, bool idle)
{
	struct rtd_ir *ir = rc->priv;

	if (idle && !READ_ONCE(ir->dying))
		schedule_work(&ir->rearm);
}

static void rtd_ir_rearm(struct work_struct *work)
{
	struct rtd_ir *ir = container_of(work, struct rtd_ir, rearm);

	if (READ_ONCE(ir->dying))
		return;
	disable_irq(ir->irq);
	reset_control_assert(ir->rst);
	udelay(1);
	reset_control_deassert(ir->rst);
	rtd_ir_hw_init(ir);
	enable_irq(ir->irq);
}

/* first thing on removal: no rearm may touch the unit after this */
static void rtd_ir_quiesce(void *data)
{
	struct rtd_ir *ir = data;

	WRITE_ONCE(ir->dying, true);
	disable_irq(ir->irq);
	cancel_work_sync(&ir->rearm);
}

static void rtd_ir_hw_stop(void *data)
{
	struct rtd_ir *ir = data;

	writel(0, ir->base + IR_CR);
}

static int rtd_ir_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct clk *clk, *ref;
	struct rtd_ir *ir;
	int ret;

	ir = devm_kzalloc(dev, sizeof(*ir), GFP_KERNEL);
	if (!ir)
		return -ENOMEM;
	ir->dev = dev;

	ir->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(ir->base))
		return PTR_ERR(ir->base);
	ir->irq = platform_get_irq(pdev, 0);
	if (ir->irq < 0)
		return ir->irq;

	clk = devm_clk_get_enabled(dev, "bus");
	if (IS_ERR(clk))
		return dev_err_probe(dev, PTR_ERR(clk), "no bus clock\n");
	/* the sampling clock: the 27 MHz crystal, not the gate */
	ref = devm_clk_get_enabled(dev, "ref");
	if (IS_ERR(ref))
		return dev_err_probe(dev, PTR_ERR(ref), "no ref clock\n");
	ir->rate = clk_get_rate(ref);
	if (ir->rate < 1000000)
		return dev_err_probe(dev, -EINVAL, "ref clock %lu Hz\n", ir->rate);
	ir->rst = devm_reset_control_get_exclusive_deasserted(dev, NULL);
	if (IS_ERR(ir->rst))
		return dev_err_probe(dev, PTR_ERR(ir->rst), "no reset\n");

	ir->rc = devm_rc_allocate_device(dev, RC_DRIVER_IR_RAW);
	if (!ir->rc)
		return -ENOMEM;
	ir->rc->priv = ir;
	ir->rc->device_name = "RTD1295 IR receiver";
	ir->rc->input_phys = DRIVER_NAME "/input0";
	ir->rc->input_id.bustype = BUS_HOST;
	ir->rc->driver_name = DRIVER_NAME;
	ir->rc->map_name = of_get_property(dev->of_node, "linux,rc-map-name",
					   NULL) ?: RC_MAP_EMPTY;
	ir->rc->allowed_protocols = RC_PROTO_BIT_ALL_IR_DECODER;
	ir->rc->rx_resolution = IR_SAMPLE_US;
	ir->rc->timeout = IR_DEFAULT_TIMEOUT;
	ir->rc->min_timeout = 10 * IR_SAMPLE_US;
	/* frames end on a space this long; the unit samples on until rearmed */
	ir->rc->max_timeout = 500 * USEC_PER_MSEC;
	ir->rc->s_idle = rtd_ir_s_idle;

	INIT_WORK(&ir->rearm, rtd_ir_rearm);
	rtd_ir_hw_init(ir);
	ret = devm_add_action_or_reset(dev, rtd_ir_hw_stop, ir);
	if (ret)
		return ret;

	ret = devm_rc_register_device(dev, ir->rc);
	if (ret)
		return ret;

	ret = devm_request_irq(dev, ir->irq, rtd_ir_irq, 0, DRIVER_NAME, ir);
	if (ret)
		return ret;
	ret = devm_add_action_or_reset(dev, rtd_ir_quiesce, ir);
	if (ret)
		return ret;

	return 0;
}

static const struct of_device_id rtd_ir_of_match[] = {
	{ .compatible = "realtek,rtd1295-ir" },
	{ }
};
MODULE_DEVICE_TABLE(of, rtd_ir_of_match);

static struct platform_driver rtd_ir_driver = {
	.probe	= rtd_ir_probe,
	.driver	= {
		.name		= DRIVER_NAME,
		.of_match_table	= rtd_ir_of_match,
	},
};
module_platform_driver(rtd_ir_driver);

MODULE_DESCRIPTION("Realtek RTD1295/RTD1296 IR receiver driver");
MODULE_AUTHOR("Jalen Lin <jalen.lin@gmail.com>");
MODULE_LICENSE("GPL");
