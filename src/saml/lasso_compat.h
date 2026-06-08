/*
 * Lasso compatibility macros for older versions
 *
 * This file provides compatibility macros for lasso versions
 * that don't have lasso/utils.h or missing certain definitions.
 */

#ifdef HAVE_LASSO_UTILS_H

#include <lasso/utils.h>

#else

#define lasso_assign_string(dest,src)           \
{                                               \
    char *__tmp = g_strdup(src);                \
    lasso_release_string(dest);                 \
    dest = __tmp;                               \
}

#define lasso_release_string(dest)              \
	lasso_release_full(dest, g_free)

#define lasso_release_full(dest, free_function) \
{                                               \
    if (dest) {                                 \
        free_function(dest); dest = NULL;       \
    }                                           \
}

#endif /* HAVE_LASSO_UTILS_H */
