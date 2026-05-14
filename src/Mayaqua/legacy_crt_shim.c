// legacy_crt_shim.c
//
// Compatibility shim for the pre-built OpenSSL static libraries shipped in
// src/BuildFiles/Library/ that were compiled against the legacy Microsoft C
// Runtime (msvcrt). The Universal CRT (UCRT, introduced in VS2015) removed
// or renamed several symbols those libraries still reference.
//
// This file is compiled into Mayaqua.lib. Any user-mode binary that links
// Mayaqua (vpncmd, vpnclient, vpnserver, vpnbridge, vpncmgr, vpnsmgr, …)
// will automatically pick up:
//
//   1. A definition of __iob_func() that returns a stdin/stdout/stderr
//      FILE-array view backed by the modern __acrt_iob_func(0|1|2).
//
//   2. A directive (via #pragma comment) that tells the linker to also
//      include legacy_stdio_definitions.lib, which restores the
//      pre-UCRT names _vsnprintf / _vsnwprintf / sscanf / _snprintf /
//      _snwprintf / etc.
//
// This is a workaround. The proper fix is to rebuild OpenSSL against
// the modern toolchain and replace the .lib files in
// src/BuildFiles/Library/{Win32,x64}_{Debug,Release}/. Once that is done,
// remove this file from Mayaqua.vcxproj.

#include <stdio.h>

#if defined(_MSC_VER) && (_MSC_VER >= 1900)

// Pulls _vsnprintf, _vsnwprintf, sscanf and friends from the MSVC
// compatibility lib. Works for both /MT and /MD CRTs.
#pragma comment(lib, "legacy_stdio_definitions.lib")

extern FILE * __cdecl __acrt_iob_func(unsigned);

// Old OpenSSL (and a few legacy MS samples) call __iob_func() to get
// the base of the historical _iob[3] table. UCRT split that table into
// three accessor calls; we synthesize the array on demand.
FILE * __cdecl __iob_func(void)
{
    static FILE iob[3];
    iob[0] = *__acrt_iob_func(0);  // stdin
    iob[1] = *__acrt_iob_func(1);  // stdout
    iob[2] = *__acrt_iob_func(2);  // stderr
    return iob;
}

#endif  // _MSC_VER >= 1900
