cmake_minimum_required(VERSION 3.20)
project(DSpellCheck LANGUAGES C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR        "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE  "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

# ---- bundled Hunspell (static) ----
file(GLOB HUNSPELL_SRC "${CMAKE_SOURCE_DIR}/deps/hunspell-src/hunspell/*.cxx")
list(REMOVE_ITEM HUNSPELL_SRC "${CMAKE_SOURCE_DIR}/deps/hunspell-src/hunspell/utf_info.cxx")
add_library(hunspell STATIC ${HUNSPELL_SRC})
target_compile_definitions(hunspell PRIVATE HUNSPELL_STATIC)
target_include_directories(hunspell PUBLIC "${CMAKE_SOURCE_DIR}/deps/hunspell-src")
target_compile_options(hunspell PRIVATE -w)   # silence 3rd-party warnings

# ---- plugin ----
add_library(DSpellCheck SHARED
    src/DSpellCheck.mm
)
target_include_directories(DSpellCheck PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
    "${CMAKE_SOURCE_DIR}/deps/hunspell-src"
    src)
target_compile_definitions(DSpellCheck PRIVATE HUNSPELL_STATIC)
target_link_libraries(DSpellCheck PRIVATE
    hunspell
    "-framework Cocoa"
    "-liconv")
target_compile_options(DSpellCheck PRIVATE
    -Wall -Wno-unused-parameter -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(DSpellCheck PROPERTIES PREFIX "" SUFFIX ".dylib")

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.nextpad++/plugins/DSpellCheck")
install(TARGETS DSpellCheck DESTINATION "${PLUGIN_INSTALL_DIR}")
install(DIRECTORY resources/ DESTINATION "${PLUGIN_INSTALL_DIR}/resources"
    PATTERN ".DS_Store" EXCLUDE PATTERN ".gitignore" EXCLUDE)
