# Third-Party Notices

DJOneHub contains code derived from the upstream VoHive project and retains the license and required notice provided in the repository root [`LICENSE`](LICENSE):

```text
Required Notice: Copyright iniwex5 (https://github.com/iniwex5/vohive)
```

## Release Runtime

The macOS release package includes **libusb 1.0.30**, distributed under the GNU Lesser General Public License, version 2.1 or later.

- Project: <https://libusb.info/>
- Source: <https://github.com/libusb/libusb/releases/tag/v1.0.30>
- License text in the release package: `licenses/libusb-COPYING`

This public-source tree contains the auditable MaVo module-side helper source
under `module/`, but intentionally does **not** contain a compiled module-side
voice runtime or any kernel-module binary. Its runtime must be cross-compiled
and deployed separately after hardware-specific validation.
See [OPEN_SOURCE_SCOPE.md](OPEN_SOURCE_SCOPE.md) for the excluded files and the
conditions required to publish a complete audio runtime.

## MaVo host-side adaptation

DJOneHub includes host-side source adapted from the public [MaVo](https://github.com/moluncn/mavo)
project, with the reference fixed at commit
[`0443dfdaf8aec086fd76ba2ee9152fd908114524`](https://github.com/moluncn/mavo/commit/0443dfdaf8aec086fd76ba2ee9152fd908114524)
(`Fix USB contention and cellular recovery`).

- Project license: [MIT](https://github.com/moluncn/mavo/blob/main/LICENSE)
- Adapted areas: UAC device probing, modem bridge declarations, macOS audio host integration,
  and the experimental ARMv7 PCM/USB-Ethernet helper source under `module/`.
- This repository does **not** redistribute a compiled MaVo module-side runtime or any kernel-module binary.

Copyright for the adapted MaVo code remains with its respective contributors;
the MIT license continues to apply to that code.

## Vendored Source Dependencies

The source repository includes vendored dependencies under `third_party/` so the versions used by DJOneHub remain reproducible. Their original copyright notices and license texts are retained in the corresponding directories.

| Component | License file |
| --- | --- |
| euicc-go | `third_party/euicc-go/LICENSE` |
| uicc-go | `third_party/uicc-go/LICENSE` |
| quectel-qmi-go | `third_party/quectel-qmi-go/LICENSE` |
| strftime | `third_party/strftime/LICENSE` |
| pkg/errors | `third_party/pkg-errors/LICENSE` |
| golang.org/x/sys | `third_party/x-sys/LICENSE` |
| golang.org/x/text | `third_party/x-text/LICENSE` |
| multierr | `third_party/multierr/LICENSE.txt` |

Dependencies fetched through Go modules retain their own licenses and copyright notices. This file is informational and does not replace any component's full license text.
