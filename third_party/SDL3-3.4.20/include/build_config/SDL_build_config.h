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

#ifndef SDL_build_config_h_
#define SDL_build_config_h_

#include <SDL3/SDL_platform_defines.h>

/**
 *  \file SDL_build_config.h
 *
 *  This is a set of defines to configure the SDL features
 */

#if defined(SDL_PLATFORM_WIN32)
#include "SDL_build_config_windows.h"
#elif defined(SDL_PLATFORM_LINUX)
#include "SDL_build_config_linux.h"
#else
#error "8-Bit supports Windows and Linux only"
#endif

#ifdef USING_GENERATED_CONFIG_H
#error Wrong SDL_build_config.h, check your include path?
#endif

#endif /* SDL_build_config_h_ */
