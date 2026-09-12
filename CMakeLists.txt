cmake_minimum_required(VERSION 3.5)

project(antigravity-proxy LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(STATIC_RUNTIME "使用静态运行库(/MT)，减少运行库依赖" ON)
option(BUILD_TESTS "构建单元测试（默认关闭）" OFF)

if(MSVC)
    add_compile_options(/utf-8)
    # 根据开关选择静态/动态运行库，减少运行库缺失导致的启动失败
    if(STATIC_RUNTIME)
        set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    else()
        set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL$<$<CONFIG:Debug>:Debug>")
    endif()
    # 统一禁用 windows.h 的 min/max 宏，避免污染 C++ 标准库的 std::min/std::max
    add_compile_definitions(NOMINMAX)
endif()

include(CMakePackageConfigHelpers)

################
#    BUILD     # 
################

if(APPLE)
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

elseif(WIN32)
  # ==============================================================================
  # Windows 编译配置：生成 version.dll 与 dbghelp.dll (基于 MinHook 与 DLL 劫持)
  # ==============================================================================
  option(BUILD_SHARED_LIBS "build shared version" OFF)

  # MinHook Sources
  set(SOURCES_MINHOOK 
    "src/buffer.c"
    "src/hook.c"
    "src/trampoline.c"
  )

  if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(SOURCES_HDE "src/hde/hde64.c")
  else()
    set(SOURCES_HDE "src/hde/hde32.c")
  endif()

  # Proxy Sources
  set(SOURCES_PROXY
    "src/main.cpp"
    "src/hooks/Hooks.cpp"
    "src/proxy/VersionProxy.cpp"
    "src/update/UpdateChecker.cpp"
  )

  # Resources
  if(BUILD_SHARED_LIBS)
    set(RESOURCES 
      "dll_resources/MinHook.rc"
      "dll_resources/MinHook.def"
    )
  endif()

  # Build antigravity-proxy DLL (输出名为 version.dll)
  add_library(version SHARED ${SOURCES_MINHOOK} ${SOURCES_HDE} ${SOURCES_PROXY} ${RESOURCES})

  # 设置模块定义文件 (导出 version.dll 函数)
  if(MSVC)
    set_target_properties(version PROPERTIES
      LINK_FLAGS "/DEF:\"${CMAKE_CURRENT_SOURCE_DIR}/src/proxy/version.def\""
    )
  else()
    target_link_options(version PRIVATE
      "-Wl,${CMAKE_CURRENT_SOURCE_DIR}/src/proxy/version.def"
    )
  endif()

  target_include_directories(version PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include/>
    $<INSTALL_INTERFACE:include>
  )

  target_include_directories(version PRIVATE "src/")
  target_include_directories(version PRIVATE "src/hde/")

  # Link WS2_32 / WinHTTP
  target_link_libraries(version PRIVATE ws2_32 winhttp)

  if(NOT MSVC AND STATIC_RUNTIME)
    target_link_options(version PRIVATE -static-libstdc++ -static-libgcc)
  endif()

  # Build Antigravity CLI shim (输出名为 dbghelp.dll)
  add_library(dbghelp SHARED
    "src/proxy/DbgHelpShim.cpp"
  )

  # CLI shim 通过定义文件导出常用 DbgHelp API，内部再延迟转发到系统 DLL。
  if(MSVC)
    set_target_properties(dbghelp PROPERTIES
      LINK_FLAGS "/DEF:\"${CMAKE_CURRENT_SOURCE_DIR}/src/proxy/dbghelp.def\""
    )
  else()
    target_link_options(dbghelp PRIVATE
      "-Wl,${CMAKE_CURRENT_SOURCE_DIR}/src/proxy/dbghelp.def"
    )
  endif()

  # CLI 使用唯一文件名加载代理主体，避免与已加载的系统 version.dll 同名冲突。
  add_dependencies(dbghelp version)
  add_custom_command(TARGET dbghelp POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:version>
            $<TARGET_FILE_DIR:dbghelp>/antigravity_proxy.dll
    COMMENT "复制 Antigravity CLI 代理主体"
  )

  set_target_properties(version PROPERTIES PREFIX "")
  set_target_properties(dbghelp PROPERTIES PREFIX "")
  if(CMAKE_SIZEOF_VOID_P EQUAL 8)   
    set_target_properties(version PROPERTIES OUTPUT_NAME "version")
    set_target_properties(dbghelp PROPERTIES OUTPUT_NAME "dbghelp")
    set_target_properties(version PROPERTIES DEBUG_POSTFIX ".x64d")
    set_target_properties(dbghelp PROPERTIES DEBUG_POSTFIX ".x64d")
    set_target_properties(version PROPERTIES RELEASE_POSTFIX "")
    set_target_properties(dbghelp PROPERTIES RELEASE_POSTFIX "")
  else()
    set_target_properties(version PROPERTIES OUTPUT_NAME "version")
    set_target_properties(dbghelp PROPERTIES OUTPUT_NAME "dbghelp")
    set_target_properties(version PROPERTIES DEBUG_POSTFIX ".x32d")
    set_target_properties(dbghelp PROPERTIES DEBUG_POSTFIX ".x32d")
    set_target_properties(version PROPERTIES RELEASE_POSTFIX "")
    set_target_properties(dbghelp PROPERTIES RELEASE_POSTFIX "")
  endif()

  install(TARGETS version dbghelp RUNTIME DESTINATION "bin")
endif()

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
  if(WIN32)
    target_link_libraries(antigravity_tests PRIVATE ws2_32)
  endif()
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
  if(WIN32)
    target_link_libraries(socket_family_tests PRIVATE ws2_32)
  endif()
  add_test(NAME socket_family_tests COMMAND socket_family_tests)

  add_executable(local_target_policy_tests
    "tests/test_local_target_policy.cpp"
  )
  target_include_directories(local_target_policy_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
  )
  if(WIN32)
    target_link_libraries(local_target_policy_tests PRIVATE ws2_32)
  endif()
  add_test(NAME local_target_policy_tests COMMAND local_target_policy_tests)

  add_executable(fakeip_tests
    "tests/test_fakeip.cpp"
  )
  target_include_directories(fakeip_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
  )
  if(WIN32)
    target_link_libraries(fakeip_tests PRIVATE ws2_32)
  endif()
  add_test(NAME fakeip_tests COMMAND fakeip_tests)

  if(WIN32)
    add_executable(dbghelp_shim_tests
      "tests/test_dbghelp_shim.cpp"
    )
    # 使用真实 CLI 进程名覆盖 shim 的代理主体加载分支。
    set_target_properties(dbghelp_shim_tests PROPERTIES OUTPUT_NAME "agy")
    add_dependencies(dbghelp_shim_tests dbghelp)
    add_test(
      NAME dbghelp_shim_tests
      COMMAND dbghelp_shim_tests "$<TARGET_FILE:dbghelp>"
    )
  endif()
endif()
