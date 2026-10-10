// SPDX-License-Identifier: GPL-2.0
/*
 * eip93-probe-test: minimal AN7583 EIP-93 hardware presence check.
 *
 * Binds the "inside-secure,safexcel-eip93ies" DT node and only READS the
 * identification registers the real driver reads. No crypto registration,
 * no ring/IRQ setup -- so it has no symbol dependency on authenc/des and can
 * be insmod'ed into an older kernel that lacks the EIP-93 driver.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/io.h>

#define EIP93_REG_PE_CTRL_STAT	0x000
#define EIP93_REG_PE_STATUS	0x104
#define EIP93_REG_PE_OPTION_1	0x1f4
#define EIP93_REG_PE_REVISION	0x1fc

static int eip93_test_probe(struct platform_device *pdev)
{
	void __iomem *base;
	u32 ctrl, status, opt1, rev;
	struct resource *res;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base)) {
		pr_err("EIP93TEST: ioremap failed: %ld\n", PTR_ERR(base));
		return PTR_ERR(base);
	}

	ctrl   = readl(base + EIP93_REG_PE_CTRL_STAT);
	status = readl(base + EIP93_REG_PE_STATUS);
	opt1   = readl(base + EIP93_REG_PE_OPTION_1);
	rev    = readl(base + EIP93_REG_PE_REVISION);

	pr_err("EIP93TEST: reg=%pR ctrl_stat=0x%08x status=0x%08x option_1=0x%08x revision=0x%08x eip_no=0x%02x hw_rev=%u.%u patch=%u\n",
	       res, ctrl, status, opt1, rev,
	       rev & 0xff, (rev >> 24) & 0xf, (rev >> 20) & 0xf, (rev >> 16) & 0xf);
	pr_err("EIP93TEST: ALGO_AES=%d ALGO_DES=%d ALGO_HASH=%d (option_1 bits)\n",
	       !!(opt1 & BIT(0)), !!(opt1 & BIT(1)), !!(opt1 & BIT(2)));

	return 0;
}

static void eip93_test_remove(struct platform_device *pdev)
{
	pr_err("EIP93TEST: removed\n");
}

static const struct of_device_id eip93_test_of_match[] = {
	{ .compatible = "inside-secure,safexcel-eip93ies" },
	{ }
};
MODULE_DEVICE_TABLE(of, eip93_test_of_match);

static struct platform_driver eip93_test_driver = {
	.probe  = eip93_test_probe,
	.remove = eip93_test_remove,
	.driver = {
		.name = "eip93-probe-test",
		.of_match_table = eip93_test_of_match,
	},
};
module_platform_driver(eip93_test_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("AN7583 EIP-93 presence probe (read-only)");
