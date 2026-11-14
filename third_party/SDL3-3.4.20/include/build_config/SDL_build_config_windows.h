/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/

#ifndef SDL_build_config_windows_h_
#define SDL_build_config_windows_h_
#define SDL_build_config_h_

#include <SDL3/SDL_platform_defines.h>

/* 8-Bit: trimmed SDL config for Windows. Only what a text editor needs:
 * windowing, input events, clipboard, timers, files and OpenGL. */

#ifdef __clang__
# define HAVE_GCC_ATOMICS 1
#endif

#define HAVE_STDINT_H 1
#define SDL_DISABLE_AVX 1

#define HAVE_STDARG_H 1
#define HAVE_STDDEF_H 1

/* This can be disabled to avoid C runtime dependencies and manifest requirements */
#ifndef HAVE_LIBC
#define HAVE_LIBC 1
#endif

#if HAVE_LIBC
/* Useful headers */
#define HAVE_FLOAT_H 1
#define HAVE_LIMITS_H 1
#define HAVE_MATH_H 1
#define HAVE_SIGNAL_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_WCHAR_H 1

/* C library functions */
#define HAVE_MALLOC 1
#define HAVE_ABS 1
#define HAVE_MEMSET 1
#define HAVE_MEMCPY 1
#define HAVE_MEMMOVE 1
#define HAVE_MEMCMP 1
#define HAVE_STRLEN 1
#define HAVE__STRREV 1
#define HAVE_STRCHR 1
#define HAVE_STRRCHR 1
#define HAVE_STRSTR 1
/* #undef HAVE_STRTOK_R */
/* These functions have security warnings, so we won't use them */
/* #undef HAVE__LTOA */
/* #undef HAVE__ULTOA */
#define HAVE_STRTOL 1
#define HAVE_STRTOUL 1
#define HAVE_STRTOD 1
#define HAVE_ATOI 1
#define HAVE_ATOF 1
#define HAVE_STRCMP 1
#define HAVE_STRNCMP 1
#define HAVE_STRPBRK 1
#define HAVE_VSNPRINTF 1
#define HAVE_ACOS 1
#define HAVE_ASIN 1
#define HAVE_ATAN 1
#define HAVE_ATAN2 1
#define HAVE_CEIL 1
#define HAVE_COS 1
#define HAVE_EXP 1
#define HAVE_FABS 1
#define HAVE_FLOOR 1
#define HAVE_FMOD 1
#define HAVE_ISINF 1
#define HAVE_ISINF_FLOAT_MACRO 1
#define HAVE_ISNAN 1
#define HAVE_ISNAN_FLOAT_MACRO 1
#define HAVE_LOG 1
#define HAVE_LOG10 1
#define HAVE_POW 1
#define HAVE_SIN 1
#define HAVE_SQRT 1
#define HAVE_TAN 1
#define HAVE_ACOSF 1
#define HAVE_ASINF 1
#define HAVE_ATANF 1
#define HAVE_ATAN2F 1
#define HAVE_CEILF 1
#define HAVE__COPYSIGN 1
#define HAVE_COSF 1
#define HAVE_EXPF 1
#define HAVE_FABSF 1
#define HAVE_FLOORF 1
#define HAVE_FMODF 1
#define HAVE_LOGF 1
#define HAVE_LOG10F 1
#define HAVE_POWF 1
#define HAVE_SINF 1
#define HAVE_SQRTF 1
#define HAVE_TANF 1
#ifdef _MSC_VER
/* These functions were added with the VC++ 2013 C runtime library */
#if _MSC_VER >= 1800
#define HAVE_STRTOLL 1
#define HAVE_STRTOULL 1
#define HAVE_VSSCANF 1
#define HAVE_LROUND 1
#define HAVE_LROUNDF 1
#define HAVE_ROUND 1
#define HAVE_ROUNDF 1
#define HAVE_SCALBN 1
#define HAVE_SCALBNF 1
#define HAVE_TRUNC 1
#define HAVE_TRUNCF 1
#endif
/* This function is available with at least the VC++ 2008 C runtime library */
#if _MSC_VER >= 1400
#define HAVE__FSEEKI64 1
#endif
#endif /* _MSC_VER */
#endif

/* Disabled subsystems */
#define SDL_AUDIO_DISABLED 1
#define SDL_CAMERA_DISABLED 1
#define SDL_JOYSTICK_DISABLED 1
#define SDL_HAPTIC_DISABLED 1
#define SDL_HIDAPI_DISABLED 1
#define SDL_SENSOR_DISABLED 1
#define SDL_GPU_DISABLED 1
#define SDL_POWER_DISABLED 1
#define SDL_DIALOG_DISABLED 1

#define SDL_PROCESS_DUMMY 1
#define SDL_TRAY_DUMMY 1

#define SDL_LOADSO_WINDOWS 1
#define SDL_THREAD_GENERIC_COND_SUFFIX 1
#define SDL_THREAD_GENERIC_RWLOCK_SUFFIX 1
#define SDL_THREAD_WINDOWS 1
#define SDL_TIME_WINDOWS 1
#define SDL_TIMER_WINDOWS 1
#define SDL_FILESYSTEM_WINDOWS 1
#define SDL_FSOPS_WINDOWS 1

#define SDL_VIDEO_DRIVER_WINDOWS 1

/* OpenGL only */
#define SDL_VIDEO_OPENGL 1
#define SDL_VIDEO_OPENGL_WGL 1
#define SDL_VIDEO_RENDER_OGL 1

#endif /* SDL_build_config_windows_h_ */
