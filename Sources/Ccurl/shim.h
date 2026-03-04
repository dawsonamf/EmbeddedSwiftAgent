#ifndef CCURL_SHIM_H
#define CCURL_SHIM_H

#include <curl/curl.h>

typedef size_t (*curl_write_callback)(char *, size_t, size_t, void *);

static inline CURLcode curl_easy_setopt_string(CURL *curl, CURLoption option, const char *param) {
    return curl_easy_setopt(curl, option, param);
}

static inline CURLcode curl_easy_setopt_long(CURL *curl, CURLoption option, long param) {
    return curl_easy_setopt(curl, option, param);
}

static inline CURLcode curl_easy_setopt_ptr(CURL *curl, CURLoption option, void *param) {
    return curl_easy_setopt(curl, option, param);
}

static inline CURLcode curl_easy_setopt_slist(CURL *curl, CURLoption option, struct curl_slist *param) {
    return curl_easy_setopt(curl, option, param);
}

static inline CURLcode curl_easy_setopt_writefunc(CURL *curl, curl_write_callback callback) {
    return curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, callback);
}

static inline CURLcode curl_easy_setopt_writedata(CURL *curl, void *data) {
    return curl_easy_setopt(curl, CURLOPT_WRITEDATA, data);
}

static inline CURLcode curl_easy_getinfo_long(CURL *curl, CURLINFO info, long *value) {
    return curl_easy_getinfo(curl, info, value);
}

#endif
