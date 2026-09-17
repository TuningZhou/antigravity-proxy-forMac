cmake_minimum_required(VERSION 3.5)

project(antigravity-proxy VERSION 2.4.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(BUILD_TESTS "构建单元测试（默认关闭）" OFF)

include(CMakePackageConfigHelpers)

################
#    BUILD     # 
################

# ==============================================================================
# macOS 编译配置：生成 libantigravity_proxy.dylib (基于 Apple Dyld Interpose 技术)
# ==============================================================================
set(CMAKE_MACOSX_RPATH 1)

set(SOURCES_PROXY_MAC
  "src/main_mac.cpp"
  "src/hooks/HooksMac.cpp"
  "src/update/UpdateChecker.cpp"
)

add_library(antigravity_proxy SHARED ${SOURCES_PROXY_MAC})

target_include_directories(antigravity_proxy PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include/>
  $<INSTALL_INTERFACE:include>
)
target_include_directories(antigravity_proxy PRIVATE "src/")

target_link_libraries(antigravity_proxy PRIVATE dl pthread)

set_target_properties(antigravity_proxy PROPERTIES
  OUTPUT_NAME "antigravity_proxy"
  PREFIX "lib"
  SUFFIX ".dylib"
  INSTALL_NAME_DIR "@rpath"
  BUILD_WITH_INSTALL_RPATH TRUE
)

install(TARGETS antigravity_proxy LIBRARY DESTINATION "lib")

###################
#      TESTS      #
###################
if(BUILD_TESTS)
  enable_testing()

  add_executable(antigravity_tests
    "tests/test_ipv6_parser.cpp"
  )
  target_include_directories(antigravity_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  )
  add_test(NAME antigravity_tests COMMAND antigravity_tests)

  add_executable(process_name_tests
    "tests/test_process_name.cpp"
  )
  target_include_directories(process_name_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
  )
  add_test(NAME process_name_tests COMMAND process_name_tests)

  add_executable(udp_policy_tests
    "tests/test_udp_policy.cpp"
  )
  target_include_directories(udp_policy_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
  )
  add_test(NAME udp_policy_tests COMMAND udp_policy_tests)

  add_executable(socket_family_tests
    "tests/test_socket_family.cpp"
  )
  target_include_directories(socket_family_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
  )
  add_test(NAME socket_family_tests COMMAND socket_family_tests)

  add_executable(local_target_policy_tests
    "tests/test_local_target_policy.cpp"
  )
  target_include_directories(local_target_policy_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
  )
  add_test(NAME local_target_policy_tests COMMAND local_target_policy_tests)

  add_executable(fakeip_tests
    "tests/test_fakeip.cpp"
  )
  target_include_directories(fakeip_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
  )
  add_test(NAME fakeip_tests COMMAND fakeip_tests)
endif()
