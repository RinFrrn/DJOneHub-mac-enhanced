// SPDX-License-Identifier: GPL-2.0
/*
 * Temporary, loadable QDC507 ASoC card used to validate direct in-call PCM.
 *
 * This module intentionally contains no PCM copy, network, UAC, or voice-DSP
 * implementation.  It reuses the components already registered by
 * qdc507_voice.ko and adds the two standard Qualcomm in-call backends that
 * the fixed-index card omits.
 */

#include <linux/err.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <sound/pcm_params.h>
#include <sound/soc.h>

#include "msm-pcm-routing-v2.h"

#define QDC507_CARD_DRIVER "qdc507-incall-card"

#define QDC507_DUMMY_CODEC "snd-soc-dummy"
#define QDC507_DUMMY_DAI "snd-soc-dummy-dai"
#define QDC507_STUB_CODEC "msm-stub-codec.1"
#define QDC507_STUB_RX "msm-stub-rx"
#define QDC507_STUB_TX "msm-stub-tx"
#define QDC507_AUXPCM_RATE 8000U
#define QDC507_VOICE_BE_RATE 48000U

#define QDC507_DYNAMIC_LINK_FLAGS                                      \
	.dynamic = 1,                                                   \
	.trigger = { SND_SOC_DPCM_TRIGGER_POST,                         \
		     SND_SOC_DPCM_TRIGGER_POST },                        \
	.ignore_suspend = 1,                                            \
	.ignore_pmdown_time = 1

#define QDC507_DUMMY_ENDPOINTS                                        \
	.codec_name = QDC507_DUMMY_CODEC,                               \
	.codec_dai_name = QDC507_DUMMY_DAI

static int qdc507_voice_be_hw_params_fixup(
	struct snd_soc_pcm_runtime *runtime,
	struct snd_pcm_hw_params *params)
{
	struct snd_interval *rate;

	(void)runtime;
	rate = hw_param_interval(params, SNDRV_PCM_HW_PARAM_RATE);
	rate->min = QDC507_VOICE_BE_RATE;
	rate->max = QDC507_VOICE_BE_RATE;
	return 0;
}

static int qdc507_auxpcm_be_hw_params_fixup(
	struct snd_soc_pcm_runtime *runtime,
	struct snd_pcm_hw_params *params)
{
	struct snd_interval *rate;
	struct snd_interval *channels;

	(void)runtime;
	rate = hw_param_interval(params, SNDRV_PCM_HW_PARAM_RATE);
	channels = hw_param_interval(params, SNDRV_PCM_HW_PARAM_CHANNELS);
	rate->min = QDC507_AUXPCM_RATE;
	rate->max = QDC507_AUXPCM_RATE;
	channels->min = 1;
	channels->max = 1;
	return 0;
}

static struct snd_soc_dai_link qdc507_incall_links[] = {
	{
		.name = "QDC507 Media1",
		.stream_name = "MultiMedia1",
		.cpu_dai_name = "MultiMedia1",
		.platform_name = "msm-pcm-dsp.0",
		QDC507_DUMMY_ENDPOINTS,
		QDC507_DYNAMIC_LINK_FLAGS,
		.dpcm_playback = 1,
		.dpcm_capture = 1,
		.be_id = MSM_FRONTEND_DAI_MULTIMEDIA1,
	},
	{
		.name = "QDC507 VoIP",
		.stream_name = "VoIP",
		.cpu_dai_name = "VoIP",
		.platform_name = "msm-voip-dsp",
		QDC507_DUMMY_ENDPOINTS,
		QDC507_DYNAMIC_LINK_FLAGS,
		.dpcm_playback = 1,
		.dpcm_capture = 1,
		.be_id = MSM_FRONTEND_DAI_VOIP,
	},
	{
		.name = "QDC507 Circuit-Switch Voice",
		.stream_name = "CS-Voice",
		.cpu_dai_name = "CS-VOICE",
		.platform_name = "msm-pcm-voice",
		QDC507_DUMMY_ENDPOINTS,
		QDC507_DYNAMIC_LINK_FLAGS,
		.no_host_mode = SND_SOC_DAI_LINK_NO_HOST,
		.dpcm_playback = 1,
		.dpcm_capture = 1,
		.be_id = MSM_FRONTEND_DAI_CS_VOICE,
	},
	{
		.name = "QDC507 Primary MI2S RX Hostless",
		.stream_name = "Primary MI2S_RX Hostless Playback",
		.cpu_dai_name = "PRI_MI2S_RX_HOSTLESS",
		.platform_name = "msm-pcm-hostless",
		QDC507_DUMMY_ENDPOINTS,
		QDC507_DYNAMIC_LINK_FLAGS,
		.no_host_mode = SND_SOC_DAI_LINK_NO_HOST,
		.dpcm_playback = 1,
		.dpcm_capture = 1,
	},
	{
		.name = "QDC507 VoLTE",
		.stream_name = "VoLTE",
		.cpu_dai_name = "VoLTE",
		.platform_name = "msm-pcm-voice",
		QDC507_DUMMY_ENDPOINTS,
		QDC507_DYNAMIC_LINK_FLAGS,
		.no_host_mode = SND_SOC_DAI_LINK_NO_HOST,
		.dpcm_playback = 1,
		.dpcm_capture = 1,
		.be_id = MSM_FRONTEND_DAI_VOLTE,
	},
	{
		.name = "QDC507 AFE PCM RX proxy",
		.stream_name = "AFE-PROXY RX",
		.cpu_dai_name = "msm-dai-q6-dev.241",
		.platform_name = "msm-pcm-afe",
		.codec_name = QDC507_STUB_CODEC,
		.codec_dai_name = QDC507_STUB_RX,
		.ignore_suspend = 1,
		.ignore_pmdown_time = 1,
		.playback_only = true,
	},
	{
		.name = "QDC507 AFE PCM TX proxy",
		.stream_name = "AFE-PROXY TX",
		.cpu_dai_name = "msm-dai-q6-dev.240",
		.platform_name = "msm-pcm-afe",
		.codec_name = QDC507_STUB_CODEC,
		.codec_dai_name = QDC507_STUB_TX,
		.ignore_suspend = 1,
		.capture_only = true,
	},
	{
		.name = LPASS_BE_AFE_PCM_RX,
		.stream_name = "AFE Playback",
		.cpu_dai_name = "msm-dai-q6-dev.224",
		.platform_name = "msm-pcm-routing",
		.codec_name = QDC507_STUB_CODEC,
		.codec_dai_name = QDC507_STUB_RX,
		.no_pcm = 1,
		.dpcm_playback = 1,
		.ignore_suspend = 1,
		.be_id = MSM_BACKEND_DAI_AFE_PCM_RX,
	},
	{
		.name = LPASS_BE_AFE_PCM_TX,
		.stream_name = "AFE Capture",
		.cpu_dai_name = "msm-dai-q6-dev.225",
		.platform_name = "msm-pcm-routing",
		.codec_name = QDC507_STUB_CODEC,
		.codec_dai_name = QDC507_STUB_TX,
		.no_pcm = 1,
		.dpcm_capture = 1,
		.ignore_suspend = 1,
		.be_id = MSM_BACKEND_DAI_AFE_PCM_TX,
	},
	{
		.name = LPASS_BE_SEC_AUXPCM_RX,
		.stream_name = "Sec AUX PCM Playback",
		.cpu_dai_name = "msm-dai-q6-auxpcm.2",
		.platform_name = "msm-pcm-routing",
		.codec_name = QDC507_STUB_CODEC,
		.codec_dai_name = QDC507_STUB_RX,
		.no_pcm = 1,
		.dpcm_playback = 1,
		.ignore_pmdown_time = 1,
		.ignore_suspend = 1,
		.be_id = MSM_BACKEND_DAI_SEC_AUXPCM_RX,
		.be_hw_params_fixup = qdc507_auxpcm_be_hw_params_fixup,
	},
	{
		.name = LPASS_BE_SEC_AUXPCM_TX,
		.stream_name = "Sec AUX PCM Capture",
		.cpu_dai_name = "msm-dai-q6-auxpcm.2",
		.platform_name = "msm-pcm-routing",
		.codec_name = QDC507_STUB_CODEC,
		.codec_dai_name = QDC507_STUB_TX,
		.no_pcm = 1,
		.dpcm_capture = 1,
		.ignore_suspend = 1,
		.be_id = MSM_BACKEND_DAI_SEC_AUXPCM_TX,
		.be_hw_params_fixup = qdc507_auxpcm_be_hw_params_fixup,
	},
	{
		.name = LPASS_BE_INCALL_RECORD_RX,
		.stream_name = "Voice Downlink Capture",
		.cpu_dai_name = "msm-dai-q6-dev.32771",
		.platform_name = "msm-pcm-routing",
		.codec_name = QDC507_STUB_CODEC,
		.codec_dai_name = QDC507_STUB_TX,
		.no_pcm = 1,
		.dpcm_capture = 1,
		.ignore_suspend = 1,
		.be_id = MSM_BACKEND_DAI_INCALL_RECORD_RX,
		.be_hw_params_fixup = qdc507_voice_be_hw_params_fixup,
	},
	{
		.name = LPASS_BE_VOICE_PLAYBACK_TX,
		.stream_name = "Voice Farend Playback",
		.cpu_dai_name = "msm-dai-q6-dev.32773",
		.platform_name = "msm-pcm-routing",
		.codec_name = QDC507_STUB_CODEC,
		.codec_dai_name = QDC507_STUB_RX,
		.no_pcm = 1,
		.dpcm_playback = 1,
		.ignore_suspend = 1,
		.be_id = MSM_BACKEND_DAI_VOICE_PLAYBACK_TX,
		.be_hw_params_fixup = qdc507_voice_be_hw_params_fixup,
	},
};

static struct snd_soc_card qdc507_incall_card = {
	.name = "qdc507-incall",
	.owner = THIS_MODULE,
	.dai_link = qdc507_incall_links,
	.num_links = ARRAY_SIZE(qdc507_incall_links),
};

static bool qdc507_incall_probed;

static void qdc507_clear_link_nodes(void)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(qdc507_incall_links); i++) {
		of_node_put(qdc507_incall_links[i].platform_of_node);
		qdc507_incall_links[i].platform_of_node = NULL;
		of_node_put(qdc507_incall_links[i].cpu_of_node);
		qdc507_incall_links[i].cpu_of_node = NULL;
		of_node_put(qdc507_incall_links[i].codec_of_node);
		qdc507_incall_links[i].codec_of_node = NULL;
	}
}

static int qdc507_populate_link_nodes(struct device_node *sound_np)
{
	struct snd_soc_dai_link *link;
	struct device_node *np;
	int i;
	int index;

	for (i = 0; i < ARRAY_SIZE(qdc507_incall_links); i++) {
		link = &qdc507_incall_links[i];

		if (link->platform_name) {
			index = of_property_match_string(sound_np,
						 "asoc-platform-names",
						 link->platform_name);
			if (index < 0)
				return index;
			np = of_parse_phandle(sound_np, "asoc-platform", index);
			if (!np)
				return -ENODEV;
			link->platform_of_node = np;
			link->platform_name = NULL;
		}

		if (link->cpu_dai_name) {
			index = of_property_match_string(sound_np,
						 "asoc-cpu-names",
						 link->cpu_dai_name);
			if (index >= 0) {
				np = of_parse_phandle(sound_np, "asoc-cpu", index);
				if (!np)
					return -ENODEV;
				link->cpu_of_node = np;
				link->cpu_dai_name = NULL;
			}
		}

		if (link->codec_name) {
			index = of_property_match_string(sound_np,
						 "asoc-codec-names",
						 link->codec_name);
			if (index >= 0) {
				np = of_parse_phandle(sound_np, "asoc-codec", index);
				if (!np)
					return -ENODEV;
				link->codec_of_node = np;
				link->codec_name = NULL;
			}
		}
	}

	return 0;
}

static int qdc507_incall_probe(struct platform_device *pdev)
{
	int ret;

	pr_err("qdc507-incall: probe entered for %s\n", dev_name(&pdev->dev));
	qdc507_incall_card.dev = &pdev->dev;
	ret = snd_soc_register_card(&qdc507_incall_card);
	if (ret) {
		dev_err(&pdev->dev, "cannot register incall card: %d\n", ret);
		qdc507_incall_card.dev = NULL;
	} else {
		qdc507_incall_probed = true;
	}
	pr_err("qdc507-incall: probe result %d\n", ret);

	return ret;
}

static int qdc507_incall_remove(struct platform_device *pdev)
{
	snd_soc_unregister_card(&qdc507_incall_card);
	qdc507_incall_card.dev = NULL;
	qdc507_incall_probed = false;
	return 0;
}

static struct platform_driver qdc507_incall_driver = {
	.probe = qdc507_incall_probe,
	.remove = qdc507_incall_remove,
	.driver = {
		.name = QDC507_CARD_DRIVER,
		.owner = THIS_MODULE,
	},
};

static int __init qdc507_incall_init(void)
{
	struct device_node *sound_np;
	int ret;

	pr_err("qdc507-incall: init start\n");
	qdc507_incall_probed = false;
	sound_np = of_find_node_by_path("/soc/sound");
	if (!sound_np)
		return -ENODEV;
	ret = qdc507_populate_link_nodes(sound_np);
	of_node_put(sound_np);
	if (ret) {
		pr_err("qdc507-incall: DT link mapping failed: %d\n", ret);
		qdc507_clear_link_nodes();
		return ret;
	}

	ret = platform_driver_register(&qdc507_incall_driver);
	if (ret) {
		pr_err("qdc507-incall: driver register failed: %d\n", ret);
		qdc507_clear_link_nodes();
		return ret;
	}

	pr_err("qdc507-incall: driver registered, probed=%u\n",
	       qdc507_incall_probed);
	if (!qdc507_incall_probed) {
		pr_err("qdc507-incall: soc:sound did not bind\n");
		platform_driver_unregister(&qdc507_incall_driver);
		qdc507_clear_link_nodes();
		return -ENODEV;
	}

	return 0;
}

static void __exit qdc507_incall_exit(void)
{
	platform_driver_unregister(&qdc507_incall_driver);
	qdc507_clear_link_nodes();
}

module_init(qdc507_incall_init);
module_exit(qdc507_incall_exit);

MODULE_DESCRIPTION("QDC507 direct in-call PCM validation card");
MODULE_LICENSE("GPL v2");
