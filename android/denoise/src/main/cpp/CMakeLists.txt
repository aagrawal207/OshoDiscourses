cmake_minimum_required(VERSION 3.22.1)
project(osho_denoise C)

# Build the vendored iOS sources in place; nothing is copied into the Android tree.
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(RNNOISE_DIR "${REPO_ROOT}/OshoDiscourses/RNNoise")
set(DEEPFILTER_INCLUDE "${REPO_ROOT}/native/deepfilter-bridge/include")
set(DEEPFILTER_LIBS "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}")

file(GLOB RNNOISE_SOURCES "${RNNOISE_DIR}/src/*.c")

add_library(osho_denoise SHARED denoise_jni.c ${RNNOISE_SOURCES})

target_include_directories(osho_denoise PRIVATE
    "${RNNOISE_DIR}/include"
    "${RNNOISE_DIR}/src"
    "${DEEPFILTER_INCLUDE}")

# RNNoise's arch.h rejects -ffast-math; iOS builds it with GCC_FAST_MATH=NO too.
target_compile_options(osho_denoise PRIVATE -O3 -fno-fast-math -w)

# Linked by name, not as an IMPORTED target: AGP would then package the same .so twice
# alongside src/main/jniLibs.
target_link_directories(osho_denoise PRIVATE "${DEEPFILTER_LIBS}")
target_link_libraries(osho_denoise PRIVATE deepfilter_bridge log m)
target_link_options(osho_denoise PRIVATE "-Wl,-z,max-page-size=16384")
