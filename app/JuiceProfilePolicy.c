#include "JuiceProfilePolicy.h"
#include <string.h>
static bool module_char(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' || c == '*';
}
static void spaces(const char *s, size_t n, size_t *i) { while (*i < n && s[*i] == ' ') ++*i; }
bool JuiceDLLOverridesValid(const char *s, size_t n)
{
    if ((!s && n) || n > 4096) return false;
    if (!n) return true;
    size_t i = 0;
    while (i < n) {
        for (;;) {
            spaces(s, n, &i); size_t begin = i;
            while (i < n && module_char(s[i])) i++;
            if (i == begin || i - begin > 255) return false;
            spaces(s, n, &i);
            if (i < n && s[i] == ',') { i++; continue; }
            if (i == n || s[i++] != '=') return false;
            break;
        }
        unsigned seen = 0;
        for (;;) {
            spaces(s, n, &i);
            if (i == n || s[i] == ';') break;
            size_t begin = i;
            while (i < n && s[i] >= 'a' && s[i] <= 'z') i++;
            size_t count = i - begin;
            unsigned bit = (count == 1 && s[begin] == 'n') ||
                           (count == 6 && !memcmp(s + begin, "native", 6)) ? 1 :
                           (count == 1 && s[begin] == 'b') ||
                           (count == 7 && !memcmp(s + begin, "builtin", 7)) ? 2 : 0;
            if (!bit || (seen & bit)) return false;
            seen |= bit; spaces(s, n, &i);
            if (i == n || s[i] == ';') break;
            if (s[i++] != ',') return false;
            spaces(s, n, &i);
            if (i == n || s[i] == ';') return false;
        }
        if (i < n) { i++; if (i == n) return false; }
    }
    return true;
}
