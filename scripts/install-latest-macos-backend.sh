#!/bin/sh
set -eu

# Developer convenience installer for GitHub Actions ZIP artifacts.  It keeps
# the installed notifier, settings and libusb intact and replaces only the
# backend binary used by the current user's LaunchAgent.

DOWNLOADS_ROOT=${1:-"${HOME}/Downloads"}
RUNTIME_BIN="${HOME}/Library/Application Support/DJOneHub/runtime/bin/djonehub-macos"
ARTIFACT_DIR="${HOME}/Library/Application Support/DJOneHub/artifacts"
LAUNCH_LABEL="gui/$(id -u)/com.jamie.djonehub"

latest_zip=
latest_mtime=0
for candidate in "${DOWNLOADS_ROOT}"/DJOneHub-macOS-universal-v1-*/*.zip; do
  [ -f "${candidate}" ] || continue
  candidate_mtime=$(stat -f '%m' "${candidate}")
  if [ "${candidate_mtime}" -gt "${latest_mtime}" ]; then
    latest_zip=${candidate}
    latest_mtime=${candidate_mtime}
  fi
done

if [ -z "${latest_zip}" ]; then
  echo "没有在 ${DOWNLOADS_ROOT}/DJOneHub-macOS-universal-v1-* 中找到 ZIP。" >&2
  exit 1
fi

checksum_file="${latest_zip}.sha256"
if [ ! -f "${checksum_file}" ]; then
  echo "缺少校验文件：${checksum_file}" >&2
  exit 1
fi

echo "使用最新测试包：${latest_zip}"
(
  cd "$(dirname -- "${latest_zip}")"
  shasum -a 256 -c "$(basename -- "${checksum_file}")"
)

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/djonehub-latest.XXXXXX")
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT HUP INT TERM

unzip -q "${latest_zip}" -d "${work_dir}"
package_binary=$(find "${work_dir}" -type f -path '*/bin/djonehub-macos' -print | head -n 1)
if [ -z "${package_binary}" ] || [ ! -x "${package_binary}" ]; then
  echo "测试包内没有可执行的 bin/djonehub-macos。" >&2
  exit 1
fi

lipo "${package_binary}" -verify_arch arm64
lipo "${package_binary}" -verify_arch x86_64
codesign --verify "${package_binary}"

# Select the newest complete ARM Actions artifact while this interactive
# terminal process still has Downloads access.  The background LaunchAgent
# must not open Downloads directly: macOS can suspend that open while waiting
# for a TCC prompt the agent cannot present.
latest_arm_dir=
latest_arm_mtime=0
for candidate in "${DOWNLOADS_ROOT}"/djonehubd-armv7-sentinel*; do
  [ -d "${candidate}" ] || continue
  [ -f "${candidate}/djonehub-voice-daemon.armv7" ] || continue
  candidate_mtime=$(stat -f '%m' "${candidate}/djonehub-voice-daemon.armv7")
  if [ "${candidate_mtime}" -gt "${latest_arm_mtime}" ]; then
    latest_arm_dir=${candidate}
    latest_arm_mtime=${candidate_mtime}
  fi
done

staged_artifacts="${work_dir}/artifacts"
if [ -n "${latest_arm_dir}" ]; then
  mkdir -p "${staged_artifacts}"
  echo "使用最新 ARM 产物：${latest_arm_dir}"
  for name in \
    djonehubd.armv7 \
    djonehub-qmi-probe.armv7 \
    djonehub-qmi-voice-control.armv7 \
    djonehub-voice-daemon.armv7 \
    djonehub-sms-daemon.armv7 \
    mavo-pcm-bridge.armv7 \
    qdc507_incall_card.new.ko
  do
    source_file="${latest_arm_dir}/${name}"
    source_checksum="${source_file}.sha256"
    if [ ! -f "${source_file}" ] || [ ! -f "${source_checksum}" ]; then
      echo "ARM 产物不完整：${source_file}" >&2
      exit 1
    fi
    (
      cd "${latest_arm_dir}"
      shasum -a 256 -c "${name}.sha256"
    )
    install -m 700 "${source_file}" "${staged_artifacts}/${name}"
    if /usr/bin/xattr -p com.apple.quarantine "${staged_artifacts}/${name}" >/dev/null 2>&1; then
      /usr/bin/xattr -d com.apple.quarantine "${staged_artifacts}/${name}"
    fi
  done
fi

if [ ! -x "${RUNTIME_BIN}" ]; then
  echo "当前用户运行目录不存在：${RUNTIME_BIN}" >&2
  echo "请先正常安装一次 DJOneHub App。" >&2
  exit 1
fi

new_binary="${RUNTIME_BIN}.new"
previous_binary="${RUNTIME_BIN}.previous"
install -m 755 "${package_binary}" "${new_binary}"

# Safari/GitHub downloads carry com.apple.quarantine into extracted files.
# Remove it only from the exact backend that passed the archive checksum,
# architecture checks, and code-signature integrity verification above.  Do
# not disable Gatekeeper or recursively clear attributes from Downloads.
if /usr/bin/xattr -p com.apple.quarantine "${new_binary}" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.quarantine "${new_binary}"
fi
if /usr/bin/xattr -p com.apple.quarantine "${new_binary}" >/dev/null 2>&1; then
  echo "无法移除新后端的 quarantine 标记，停止安装。" >&2
  rm -f "${new_binary}"
  exit 1
fi

cp -p "${RUNTIME_BIN}" "${previous_binary}"
mv -f "${new_binary}" "${RUNTIME_BIN}"
launchctl kickstart -k "${LAUNCH_LABEL}"

attempt=0
# USB enumeration and the first AT probe can take 10-15 seconds on QDC507.
# Keep the check bounded, but do not mistake normal cold-start latency for a
# broken build and roll back a healthy backend.
while [ "${attempt}" -lt 60 ]; do
  if curl -fsS --max-time 2 http://127.0.0.1:7575/api/health >/dev/null 2>&1; then
    if [ -d "${staged_artifacts}" ]; then
      mkdir -p "${ARTIFACT_DIR}"
      for staged in "${staged_artifacts}"/*.armv7 "${staged_artifacts}"/*.ko; do
        [ -f "${staged}" ] || continue
        install -m 700 "${staged}" "${ARTIFACT_DIR}/$(basename -- "${staged}").new"
        mv -f "${ARTIFACT_DIR}/$(basename -- "${staged}").new" "${ARTIFACT_DIR}/$(basename -- "${staged}")"
      done
      echo "ARM 产物已缓存到：${ARTIFACT_DIR}"
    fi
    echo "安装完成，后端健康检查通过。"
    echo "上一个后端保存在：${previous_binary}"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 0.5
done

echo "新后端未通过健康检查，正在恢复上一版本。" >&2
install -m 755 "${previous_binary}" "${RUNTIME_BIN}"
launchctl kickstart -k "${LAUNCH_LABEL}"
exit 1
