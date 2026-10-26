# Mayhem fuzz harnesses, built against an installed (static, sanitized) OpenColorIO.
# Driven by mayhem/build.sh; not part of upstream's build.
cmake_minimum_required(VERSION 3.20)
project(ocio_mayhem_harness CXX C)

find_package(OpenColorIO REQUIRED CONFIG)

set(HARNESSES fuzz_config fuzz_filetransform fuzz_ocioz)

# LLVM's run-once driver, compiled as C so LLVMFuzzerTestOneInput keeps C linkage.
add_library(standalone_main OBJECT "$ENV{STANDALONE_FUZZ_MAIN}")
set_source_files_properties("$ENV{STANDALONE_FUZZ_MAIN}" PROPERTIES LANGUAGE C)

foreach(h ${HARNESSES})
    add_executable(${h} ${h}.cc ${LSAN_OFF_OBJ})
    target_link_libraries(${h} PRIVATE OpenColorIO::OpenColorIO $ENV{LIB_FUZZING_ENGINE})
    add_executable(${h}-standalone ${h}.cc ${LSAN_OFF_OBJ} $<TARGET_OBJECTS:standalone_main>)
    target_link_libraries(${h}-standalone PRIVATE OpenColorIO::OpenColorIO)
endforeach()
