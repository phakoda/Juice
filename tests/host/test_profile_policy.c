#include "JuiceProfilePolicy.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void)
{
    const char *valid[] = {"", "d3d11,dxgi=n,b", "mscoree,mshtml=", "*foo.dll=b,n;bar=native,builtin", " foo = builtin ", "x=;y=b"};
    const char *invalid[] = {" ", "x", "=n", "x==n", "x=foo", "x=n,n", "x=n,", "x=n;", "x=;", "x,=b", "x=n;=b", "x=native,n", "x=,b", "x=b;n", "x=b\n", "x=/tmp/foo", "x=b; y=$HOME", "x=b,n,b"};
    for (size_t i = 0; i < sizeof(valid)/sizeof(*valid); i++) assert(JuiceDLLOverridesValid(valid[i], strlen(valid[i])));
    for (size_t i = 0; i < sizeof(invalid)/sizeof(*invalid); i++) assert(!JuiceDLLOverridesValid(invalid[i], strlen(invalid[i])));
    assert(!JuiceDLLOverridesValid("x=b\0y=n", 7));
    char long_text[4097]; memset(long_text, 'a', sizeof(long_text)); assert(!JuiceDLLOverridesValid(long_text, sizeof(long_text)));
    assert(JuiceDLLOverridesValid(NULL, 0)); assert(!JuiceDLLOverridesValid(NULL, 1));
    for (unsigned int c = 0; c < 256; c++) { char sample[] = {'x','=',(char)c,0}; (void)JuiceDLLOverridesValid(sample, 3); }
    puts("DLL_PROFILE_POLICY_OK valid=6 invalid=18 bounds_nul_bytes=pass");
    return 0;
}
