//  RepoPrompt-Bridging-Header.h
//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#ifndef RepoPrompt_Bridging_Header_h
#define RepoPrompt_Bridging_Header_h

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/ptrace.h>
#include <unistd.h>
#include <stdbool.h>

// Define PT_DENY_ATTACH if not already defined
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif


// Bundled wildmatch matcher for gitignore-compatible pattern matching
int repo_wildmatch(const char *pattern, const char *text, unsigned int flags);

// Gitignore-specific matching (single declaration source shared with the domain runtime)
#include "../../RepoPromptC/include/repo_gitignore.h"

// String extensions from string_extensions_wrapper.h
#include "../../RepoPromptC/include/string_extensions_wrapper.h"

// Search scoring functions
#include "../../RepoPromptC/include/search_scoring.h"

// Path search functions
#include "../../RepoPromptC/include/path_search.h"


// PCRE2 regex (vendored from SwiftPCRE2)
#include "../../CSwiftPCRE2/include/CSwiftPCRE2.h"

#endif /* RepoPrompt_Bridging_Header_h */
