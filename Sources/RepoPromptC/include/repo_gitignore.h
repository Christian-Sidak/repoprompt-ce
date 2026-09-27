#ifndef REPO_GITIGNORE_H
#define REPO_GITIGNORE_H

#include <stdbool.h>
#include <stddef.h>

// Gitignore-specific matching over the bundled wildmatch implementation
// (src/wildmatch/repo_wildmatch_wrapper.c). Shared by the app crawl and the
// domain runtime so both compile and match ignore patterns identically.
int repo_gitignore_match_anchored(const char *pattern, const char *path);
int repo_gitignore_match_anywhere(const char *pattern, const char *path);
void repo_normalize_pattern(char *dest, const char *src, size_t dest_size);

// Parsed gitignore line.
typedef struct {
    char pattern[1024];
    bool is_negation;
    bool directory_only;
    bool absolute;
} repo_gitignore_pattern;

// Parse one gitignore line; returns false for blank or comment lines.
bool repo_parse_gitignore_line(const char *line, repo_gitignore_pattern *result);

#endif
