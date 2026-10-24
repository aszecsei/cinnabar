// C helpers that Luau's C API needs but does not provide.
#include <stdlib.h>

// luau_compile returns memory from Luau's CRT, which must free it. Odin cannot call that CRT's free directly when Luau
// is a DLL.
CN_LUAU_API void cn_luau_free(void* p)
{
    free(p);
}
