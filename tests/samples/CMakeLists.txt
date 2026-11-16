cmake_minimum_required(VERSION 3.20)
# The project.
project(sample C)

set(SOURCES main.c "util.c")
add_executable(sample ${SOURCES})
if(WIN32)
  target_compile_definitions(sample PRIVATE ON)
endif()
