#!/bin/bash
#
# AV3A 构建：arm64-v8a 使用共享库 + libarcdav3a；armeabi-v7a / x86 为静态 FFmpeg（无 AV3A 预编译库）。
#
set -eu

FFMPEG_MODULE_PATH="$1"
echo "FFMPEG_MODULE_PATH is ${FFMPEG_MODULE_PATH}"
NDK_PATH="$2"
echo "NDK path is ${NDK_PATH}"
HOST_PLATFORM="$3"
echo "Host platform is ${HOST_PLATFORM}"
ANDROID_ABI="$4"
echo "ANDROID_ABI is ${ANDROID_ABI}"
ENABLED_DECODERS=("${@:5}")
echo "Enabled decoders are ${ENABLED_DECODERS[@]}"
JOBS="$(nproc 2> /dev/null || sysctl -n hw.ncpu 2> /dev/null || echo 4)"
echo "Using $JOBS jobs for make"

FFMPEG_SRC="${FFMPEG_MODULE_PATH}/jni/ffmpeg"
DEP_ROOT="${FFMPEG_SRC}/dependency/android"

copy_av3a_prebuilt() {
  local out_abi="$1"
  local dep_cpu="$2"
  local out_dir="${FFMPEG_SRC}/android-libs/${out_abi}"
  local dep_dir="${DEP_ROOT}/${dep_cpu}"
  for lib in libav3a_binaural_render.so libAVS3AudioDec.so; do
    if [[ ! -f "${dep_dir}/${lib}" ]]; then
      echo "missing ${dep_dir}/${lib}"
      exit 1
    fi
    cp -f "${dep_dir}/${lib}" "${out_dir}/"
    # 预编译库本身没有 DT_SONAME。若直接以全路径链入 libffmpegJNI.so，
    # 链接器会把构建机的绝对路径（/home/runner/.../libxxx.so）写进 DT_NEEDED，
    # 设备上该路径不存在 → dlopen 整体失败（CANNOT LINK ... library not found）→ 有画无声。
    # 显式补一个 basename soname，使后续链接记录的 DT_NEEDED 为文件名，运行时按名解析。
    patchelf --set-soname "${lib}" "${out_dir}/${lib}"
  done
  # av3a 预编译库（libav3a_binaural_render.so / libAVS3AudioDec.so）依赖 NDK 的
  # C++ 共享运行时 libc++_shared.so。libffmpegJNI 默认以 c++_static 链接，不会把它打进包，
  # 缺失时设备上 dlopen 报 "library libc++_shared.so not found" → 仍然有画无声。
  # 从 NDK sysroot 复制到 android-libs，使其随 jniLibs 一并打进 AAR/APK。
  local stl_triple=""
  case "${out_abi}" in
    arm64-v8a)   stl_triple="aarch64-linux-android" ;;
    armeabi-v7a) stl_triple="arm-linux-androideabi" ;;
  esac
  if [[ -n "${stl_triple}" ]]; then
    local stl_src="${NDK_PATH}/toolchains/llvm/prebuilt/${HOST_PLATFORM}/sysroot/usr/lib/${stl_triple}/libc++_shared.so"
    if [[ -f "${stl_src}" ]]; then
      cp -f "${stl_src}" "${out_dir}/"
      echo "copied libc++_shared.so for ${out_abi} from ${stl_src}"
    else
      echo "ERROR: libc++_shared.so not found at ${stl_src}"
      exit 1
    fi
  fi
}

ARM_AV3A_OPTIONS="
 --target-os=android
 --disable-static
 --enable-shared
 --disable-doc
 --disable-programs
 --disable-everything
 --disable-avdevice
 --enable-avformat
 --enable-swscale
 --disable-postproc
 --disable-avfilter
 --disable-symver
 --enable-swresample
 --extra-ldexeflags=-pie
 --disable-v4l2-m2m
 --disable-vulkan
 --enable-libarcdav3a
 --enable-decoders
 --enable-decoder=libarcdav3a
 --disable-decoder=av1
 "

X86_STATIC_OPTIONS="
 --target-os=android
 --enable-static
 --disable-shared
 --disable-doc
 --disable-programs
 --disable-everything
 --disable-avdevice
 --disable-avformat
 --disable-swscale
 --disable-postproc
 --disable-avfilter
 --disable-symver
 --enable-swresample
 --extra-ldexeflags=-pie
 --disable-v4l2-m2m
 --disable-vulkan
 --disable-decoder=av1,vp9
 "

# x86 / armeabi-v7a 无 AV3A 软解；补丁 FFmpeg 6.1 在 --disable-asm 下编 av1 会缺 libavutil 符号（ff_av1_framerate）
X86_SKIP_DECODERS=(libarcdav3a av1 vp9)
ARMV7_SKIP_DECODERS=(libarcdav3a av1)

TOOLCHAIN_PREFIX="${NDK_PATH}/toolchains/llvm/prebuilt/${HOST_PLATFORM}/bin"
if [[ ! -d "${TOOLCHAIN_PREFIX}" ]]; then
  echo "Please set correct NDK_PATH, $NDK_PATH is incorrect"
  exit 1
fi

ARMV7_CLANG="${TOOLCHAIN_PREFIX}/armv7a-linux-androideabi${ANDROID_ABI}-clang"
if [[ ! -e "$ARMV7_CLANG" ]]; then
  echo "ARMv7 Clang compiler with path $ARMV7_CLANG does not exist"
  exit 1
fi
ANDROID_ABI_64BIT="$ANDROID_ABI"
if [[ "$ANDROID_ABI_64BIT" -lt 21 ]]; then
  ANDROID_ABI_64BIT=21
fi

build_arm_av3a() {
  local out_abi="$1"
  local dep_cpu="$2"
  shift 2
  local -a extra_configure=("$@")
  local options="${ARM_AV3A_OPTIONS}"
  for decoder in "${ENABLED_DECODERS[@]}"; do
    # 补丁版 FFmpeg 6.1 的 av1 解码器引用 ff_av1_framerate，但共享库未导出该符号，
    # 运行时 libffmpegJNI 加载会因 "cannot locate symbol ff_av1_framerate" 整体失败
    # → 菁彩声仍有画无声。与 x86 一致跳过 av1 软解（设备 AV1 走硬解，不影响）。
    [[ "${decoder}" == "av1" ]] && continue
    options="${options} --enable-decoder=${decoder}"
  done
  cd "${FFMPEG_SRC}"
  bash ./configure "${extra_configure[@]}" ${options}
  make -j"$JOBS"
  make install-libs
  copy_av3a_prebuilt "${out_abi}" "${dep_cpu}"
  make clean
}

build_x86_static() {
  local -a extra_configure=("$@")
  local options="${X86_STATIC_OPTIONS}"
  for decoder in "${ENABLED_DECODERS[@]}"; do
    local skip=0
    for x in "${X86_SKIP_DECODERS[@]}"; do
      [[ "${decoder}" == "${x}" ]] && skip=1 && break
    done
    [[ "${skip}" -eq 1 ]] && continue
    options="${options} --enable-decoder=${decoder}"
  done
  cd "${FFMPEG_SRC}"
  bash ./configure "${extra_configure[@]}" ${options}
  make -j"$JOBS"
  make install-libs
  make clean
}

# armeabi-v7a：第三方预编译 AVS3 库与 Android 32 位 linker 不兼容（DT_RELASZ / 缺 GNU_HASH），
# 故 32 位 ARM 走静态 FFmpeg（无 libarcdav3a），菁彩声仅 arm64-v8a 专包路径提供。
build_armv7_static() {
  local -a extra_configure=("$@")
  local options="${X86_STATIC_OPTIONS}"
  for decoder in "${ENABLED_DECODERS[@]}"; do
    local skip=0
    for x in "${ARMV7_SKIP_DECODERS[@]}"; do
      [[ "${decoder}" == "${x}" ]] && skip=1 && break
    done
    [[ "${skip}" -eq 1 ]] && continue
    options="${options} --enable-decoder=${decoder}"
  done
  cd "${FFMPEG_SRC}"
  bash ./configure "${extra_configure[@]}" ${options}
  make -j"$JOBS"
  make install-libs
  make clean
}

build_armv7_static \
  --libdir=android-libs/armeabi-v7a \
  --arch=arm \
  --cpu=armv7-a \
  --cross-prefix="${TOOLCHAIN_PREFIX}/armv7a-linux-androideabi${ANDROID_ABI}-" \
  --nm="${TOOLCHAIN_PREFIX}/llvm-nm" \
  --ar="${TOOLCHAIN_PREFIX}/llvm-ar" \
  --ranlib="${TOOLCHAIN_PREFIX}/llvm-ranlib" \
  --strip="${TOOLCHAIN_PREFIX}/llvm-strip" \
  --extra-cflags="-march=armv7-a -mfloat-abi=softfp" \
  --extra-ldflags="-Wl,--fix-cortex-a8"

build_arm_av3a arm64-v8a armv8-a \
  --libdir=android-libs/arm64-v8a \
  --arch=aarch64 \
  --cpu=armv8-a \
  --cross-prefix="${TOOLCHAIN_PREFIX}/aarch64-linux-android${ANDROID_ABI_64BIT}-" \
  --nm="${TOOLCHAIN_PREFIX}/llvm-nm" \
  --ar="${TOOLCHAIN_PREFIX}/llvm-ar" \
  --ranlib="${TOOLCHAIN_PREFIX}/llvm-ranlib" \
  --strip="${TOOLCHAIN_PREFIX}/llvm-strip"

build_x86_static \
  --libdir=android-libs/x86 \
  --arch=x86 \
  --cpu=i686 \
  --cross-prefix="${TOOLCHAIN_PREFIX}/i686-linux-android${ANDROID_ABI}-" \
  --nm="${TOOLCHAIN_PREFIX}/llvm-nm" \
  --ar="${TOOLCHAIN_PREFIX}/llvm-ar" \
  --ranlib="${TOOLCHAIN_PREFIX}/llvm-ranlib" \
  --strip="${TOOLCHAIN_PREFIX}/llvm-strip" \
  --disable-asm

build_x86_static \
  --libdir=android-libs/x86_64 \
  --arch=x86_64 \
  --cpu=x86-64 \
  --cross-prefix="${TOOLCHAIN_PREFIX}/x86_64-linux-android${ANDROID_ABI_64BIT}-" \
  --nm="${TOOLCHAIN_PREFIX}/llvm-nm" \
  --ar="${TOOLCHAIN_PREFIX}/llvm-ar" \
  --ranlib="${TOOLCHAIN_PREFIX}/llvm-ranlib" \
  --strip="${TOOLCHAIN_PREFIX}/llvm-strip" \
  --disable-asm
