#

# AV3A 版 CMake：arm64-v8a 链接共享 FFmpeg + AVS3 伴生库；armeabi-v7a / x86 保持上游静态链接。

#

cmake_minimum_required(VERSION 3.21.0 FATAL_ERROR)



set(CMAKE_CXX_STANDARD 11)



project(libffmpegJNI C CXX)



set(ffmpeg_location "${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg")

set(ffmpeg_binaries "${ffmpeg_location}/android-libs/${ANDROID_ABI}")



find_library(android_log_lib log)



# 仅 arm64-v8a 链接 AV3A 共享库；armeabi-v7a 走下方静态 FFmpeg 分支（无菁彩声原生解码）。
if(ANDROID_ABI STREQUAL "arm64-v8a")

  foreach(ffmpeg_lib avutil swresample avcodec swscale av3a_binaural_render AVS3AudioDec c++_shared)

    set(ffmpeg_lib_filename lib${ffmpeg_lib}.so)

    set(ffmpeg_lib_file_path ${ffmpeg_binaries}/${ffmpeg_lib_filename})

    add_library(

      ${ffmpeg_lib}

      SHARED

      IMPORTED)

    set_target_properties(

      ${ffmpeg_lib} PROPERTIES

      IMPORTED_LOCATION

      ${ffmpeg_lib_file_path})

  endforeach()



  include_directories(${ffmpeg_location})



  add_library(ffmpegJNI

    SHARED

    ffmpeg_jni.cc)



  target_link_libraries(ffmpegJNI

    PRIVATE android

    PRIVATE m

    PRIVATE swresample

    PRIVATE avcodec

    PRIVATE avutil

    PRIVATE swscale

    PRIVATE av3a_binaural_render

    PRIVATE AVS3AudioDec

    PRIVATE c++_shared

    PRIVATE ${android_log_lib})

else()

  foreach(ffmpeg_lib avutil swresample avcodec)

    set(ffmpeg_lib_filename lib${ffmpeg_lib}.a)

    set(ffmpeg_lib_file_path ${ffmpeg_binaries}/${ffmpeg_lib_filename})

    add_library(

      ${ffmpeg_lib}

      STATIC

      IMPORTED)

    set_target_properties(

      ${ffmpeg_lib} PROPERTIES

      IMPORTED_LOCATION

      ${ffmpeg_lib_file_path})

  endforeach()



  include_directories(${ffmpeg_location})



  add_library(ffmpegJNI

    SHARED

    ffmpeg_jni.cc)



  target_link_libraries(ffmpegJNI

    PRIVATE android

    PRIVATE swresample

    PRIVATE avcodec

    PRIVATE avutil

    PRIVATE ${android_log_lib})

endif()



if(ANDROID_ABI STREQUAL "arm64-v8a")

  target_link_options(ffmpegJNI PRIVATE "-Wl,-Bsymbolic")

endif()

