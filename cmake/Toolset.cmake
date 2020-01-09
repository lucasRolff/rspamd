option (ENABLE_FAST_MATH     "Build rspamd with fast math compiler flag [default: ON]" ON)

if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
    SET (COMPILER_GCC 1)
elseif(CMAKE_C_COMPILER_ID MATCHES "Clang|AppleClang")
    SET (COMPILER_CLANG 1)
endif()

SET (COMPILER_FAST_MATH "")
if (ENABLE_FAST_MATH MATCHES "ON")
    # We need to keep nans and infinities, so cannot keep all fast math there
    IF (COMPILER_CLANG)
        SET (COMPILER_FAST_MATH "-fassociative-math -freciprocal-math -fno-signed-zeros -ffp-contract=fast")
    ELSE()
        SET (COMPILER_FAST_MATH "-funsafe-math-optimizations -fno-math-errno")
    ENDIF ()
endif ()

if (CMAKE_GENERATOR STREQUAL "Ninja")
    # Turn on colored output. https://github.com/ninja-build/ninja/wiki/FAQ
    set (CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fdiagnostics-color=always")
    set (CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fdiagnostics-color=always")
endif ()

if (COMPILER_GCC)
    # Require minimum version of gcc
    set (GCC_MINIMUM_VERSION 4)
    if (CMAKE_C_COMPILER_VERSION VERSION_LESS ${GCC_MINIMUM_VERSION} AND NOT CMAKE_VERSION VERSION_LESS 2.8.9)
        message (FATAL_ERROR "GCC version must be at least ${GCC_MINIMUM_VERSION}.")
    endif ()
elseif (COMPILER_CLANG)
    # Require minimum version of clang
    set (CLANG_MINIMUM_VERSION 4)
    if (CMAKE_C_COMPILER_VERSION VERSION_LESS ${CLANG_MINIMUM_VERSION})
        message (FATAL_ERROR "Clang version must be at least ${CLANG_MINIMUM_VERSION}.")
    endif ()
    ADD_COMPILE_OPTIONS(-Wno-unused-command-line-argument)
else ()
    message (WARNING "You are using an unsupported compiler ${CMAKE_C_COMPILER_ID}. Compilation has only been tested with Clang 4+ and GCC 4+.")
endif ()

option(LINKER_NAME "Linker name or full path")

find_program(LLD_PATH NAMES "ld.lld" "lld")
find_program(GOLD_PATH NAMES "ld.gold" "gold")

if(NOT LINKER_NAME)
    if(LLD_PATH)
        set(LINKER_NAME "lld")
    elseif(GOLD_PATH)
        set(LINKER_NAME "gold")
    else()
        message(STATUS "Use generic 'ld' as a linker")
    endif()
endif()

if(LINKER_NAME)
    set (CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -fuse-ld=${LINKER_NAME}")
    set (CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -fuse-ld=${LINKER_NAME}")

    message(STATUS "Using custom linker by name: ${LINKER_NAME}")
endif ()

option (ENABLE_STATIC       "Enable static compiling [default: OFF]"             OFF)

if (ENABLE_STATIC MATCHES "ON")
    MESSAGE(STATUS "Static build of rspamd implies that the target binary will be *GPL* licensed")
    SET(GPL_RSPAMD_BINARY 1)
    SET(CMAKE_SKIP_INSTALL_RPATH ON)
    SET(BUILD_STATIC 1)
    SET(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
    SET(BUILD_SHARED_LIBRARIES OFF)
    SET(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -static")
    SET(LINK_TYPE "STATIC")
    SET(NO_SHARED "ON")
    # Dirty hack for cmake
    SET(CMAKE_EXE_LINK_DYNAMIC_C_FLAGS)       # remove -Wl,-Bdynamic
    SET(CMAKE_EXE_LINK_DYNAMIC_CXX_FLAGS)
    SET(CMAKE_SHARED_LIBRARY_C_FLAGS)         # remove -fPIC
    SET(CMAKE_SHARED_LIBRARY_CXX_FLAGS)
    SET(CMAKE_SHARED_LIBRARY_LINK_C_FLAGS)    # remove -rdynamic
    SET(CMAKE_SHARED_LIBRARY_LINK_CXX_FLAGS)
else ()
    if (NO_SHARED MATCHES "OFF")
        SET(LINK_TYPE "SHARED")
    else ()
        SET(LINK_TYPE "STATIC")
    endif ()
endif ()

# Google performance tools
option (ENABLE_GPERF_TOOLS  "Enable google perftools [default: OFF]"             OFF)
if (ENABLE_GPERF_TOOLS MATCHES "ON")
    ProcessPackage(GPERF LIBRARY profiler INCLUDE profiler.h INCLUDE_SUFFIXES include/google
            ROOT ${GPERF_ROOT_DIR})
    set (CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fno-omit-frame-pointer")
    set (CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-omit-frame-pointer")
    set (WITH_GPERF_TOOLS 1)
endif (ENABLE_GPERF_TOOLS MATCHES "ON")

# Legacy options support
option (ENABLE_COVERAGE     "Build rspamd with code coverage options [default: OFF]" OFF)
option (ENABLE_OPTIMIZATION "Enable extra optimizations [default: OFF]"          OFF)
option (SKIP_RELINK_RPATH   "Skip relinking and full RPATH for the install tree" OFF)
option (ENABLE_FULL_DEBUG   "Build rspamd with all possible debug [default: OFF]" OFF)

if(NOT CMAKE_BUILD_TYPE)
    if (ENABLE_FULL_DEBUG MATCHES "ON")
        set(CMAKE_BUILD_TYPE Debug CACHE STRING "" FORCE)
    endif()
    if (ENABLE_COVERAGE MATCHES "ON")
        set(CMAKE_BUILD_TYPE Coverage CACHE STRING "" FORCE)
    endif()
    if (ENABLE_OPTIMIZATION MATCHES "ON")
        set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
    endif()
endif()

if (CMAKE_CONFIGURATION_TYPES) # multiconfig generator?
    set (CMAKE_CONFIGURATION_TYPES "Debug;RelWithDebInfo;Release;Coverage" CACHE STRING "" FORCE)
else()
    if (NOT CMAKE_BUILD_TYPE)
        if (NOT SANITIZE)
            message(STATUS "Defaulting to release build.")
            set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
        else ()
            message(STATUS "Defaulting to debug build due to sanitizers being enabled.")
            set(CMAKE_BUILD_TYPE Debug CACHE STRING "" FORCE)
        endif ()
    endif()
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY HELPSTRING "Choose the type of build")
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS "Debug;Release;Coverage")
endif()

string(TOUPPER ${CMAKE_BUILD_TYPE} CMAKE_BUILD_TYPE_UC)
message (STATUS "CMAKE_BUILD_TYPE: ${CMAKE_BUILD_TYPE_UC}")
set(CMAKE_C_FLAGS_COVERAGE             "${CMAKE_C_FLAGS} -O1 --coverage -fno-inline -fno-default-inline -fno-inline-small-functions ${COMPILER_FAST_MATH}")
set(CMAKE_CXX_FLAGS_COVERAGE           "${CMAKE_CXX_FLAGS} -O1 --coverage -fno-inline -fno-default-inline -fno-inline-small-functions ${COMPILER_FAST_MATH}")

if (COMPILER_GCC)
    # GCC flags
    set (COMPILER_DEBUG_FLAGS "-g -ggdb -g3 -ggdb3")
    set (CMAKE_C_FLAGS_RELWITHDEBINFO      "${CMAKE_C_FLAGS_RELEASE} -O2 ${COMPILER_FAST_MATH} ${COMPILER_DEBUG_FLAGS}")
    set (CMAKE_CXX_FLAGS_RELWITHDEBINFO    "${CMAKE_CXX_FLAGS_RELEASE} -O2 ${COMPILER_FAST_MATH} ${COMPILER_DEBUG_FLAGS}")

    set (CMAKE_C_FLAGS_RELEASE         "${CMAKE_C_FLAGS_RELEASE} -O3 ${COMPILER_FAST_MATH} -fomit-frame-pointer")
    set (CMAKE_CXX_FLAGS_RELEASE       "${CMAKE_CXX_FLAGS_RELEASE} -O3 ${COMPILER_FAST_MATH} -fomit-frame-pointer")

    set (CMAKE_C_FLAGS_DEBUG           "${CMAKE_C_FLAGS_DEBUG} -Og ${COMPILER_FAST_MATH} ${COMPILER_DEBUG_FLAGS}")
    set (CMAKE_CXX_FLAGS_DEBUG         "${CMAKE_CXX_FLAGS_DEBUG} -Og ${COMPILER_FAST_MATH} ${COMPILER_DEBUG_FLAGS}")
else ()
    # Clang flags
    if (LINKER_NAME MATCHES "lld")
        set (COMPILER_DEBUG_FLAGS "-g -glldb -gdwarf-aranges -gdwarf-5")
    else ()
        set (COMPILER_DEBUG_FLAGS "-g -glldb -gdwarf-aranges -gdwarf-4")
    endif ()
    set (CMAKE_C_FLAGS_RELEASE         "${CMAKE_C_FLAGS_RELEASE} -O2 -fomit-frame-pointer ${COMPILER_FAST_MATH}")
    set (CMAKE_CXX_FLAGS_RELEASE       "${CMAKE_CXX_FLAGS_RELEASE} -O2 -fomit-frame-pointer ${COMPILER_FAST_MATH}")

    set (CMAKE_C_FLAGS_RELWITHDEBINFO      "${CMAKE_C_FLAGS_RELEASE} -O2 ${COMPILER_FAST_MATH} ${COMPILER_DEBUG_FLAGS}")
    set (CMAKE_CXX_FLAGS_RELWITHDEBINFO    "${CMAKE_CXX_FLAGS_RELEASE} -O2 ${COMPILER_FAST_MATH} ${COMPILER_DEBUG_FLAGS}")

    set (CMAKE_C_FLAGS_DEBUG           "${CMAKE_C_FLAGS_DEBUG} -O0 ${COMPILER_FAST_MATH} ${COMPILER_DEBUG_FLAGS}")
    set (CMAKE_CXX_FLAGS_DEBUG         "${CMAKE_CXX_FLAGS_DEBUG} -O0 ${COMPILER_FAST_MATH} ${COMPILER_DEBUG_FLAGS}")
endif()


if (CMAKE_BUILD_TYPE_UC MATCHES "COVERAGE")
    set (CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} --coverage")
elseif (CMAKE_BUILD_TYPE_UC MATCHES "RELEASE")
    if (${CMAKE_VERSION} VERSION_GREATER "3.9.0")
        cmake_policy (SET CMP0069 NEW)
        include (CheckIPOSupported)
        check_ipo_supported (RESULT SUPPORT_LTO OUTPUT LTO_DIAG )
        if (SUPPORT_LTO)
            set (CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
            message (STATUS "Enable IPO for the ${CMAKE_BUILD_TYPE} build")
        else ()
            message(WARNING "IPO is not supported: ${LTO_DIAG}")
        endif ()
    endif ()
endif ()

message (STATUS "Final CFLAGS: ${CMAKE_C_FLAGS} ${CMAKE_C_FLAGS_${CMAKE_BUILD_TYPE_UC}}")
message (STATUS "Final CXXFLAGS: ${CMAKE_CXX_FLAGS} ${CMAKE_C_FLAGS_${CMAKE_BUILD_TYPE_UC}}")