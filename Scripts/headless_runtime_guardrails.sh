#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

runtime_sources="Sources/RepoPromptDomainRuntime"
direct_sources="Sources/RepoPromptMCP"

if grep -R -n -E '^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI)([[:space:]]|$)' "$runtime_sources"; then
  echo "error: RepoPromptDomainRuntime must remain independent of AppKit and SwiftUI" >&2
  exit 1
fi

for forbidden in \
  MCPFoundationStandaloneBackend \
  MCPDomainCanonicalToolManifest \
  RECORD_MCP_WINDOW_TOOL_CATALOG \
  MCPServerViewModel; do
  if grep -R -n --include='*.swift' --include='*.json' "$forbidden" "$runtime_sources" "$direct_sources"; then
    echo "error: forbidden duplicate or app-owned headless authority: $forbidden" >&2
    exit 1
  fi
done

for retired in \
  ServiceRegistry \
  MCPWindowToolRuntime \
  MCPWindowToolDependencies \
  MCPWindowToolContext \
  MCPWindowToolCatalogService \
  MCPWindowToolGroup \
  MCPAppToolDependencies \
  sharedBindingRuntime \
  appAdapterTools \
  activeTabCompatibility \
  PresentationActiveContextFallback \
  usesPresentationActiveContext \
  allowLegacyImplicitRouting \
  shouldUseGenericTabBindingCompatibility \
  TabScopedContext \
  DomainProtectedMutationStage \
  migratedToolNames; do
  if grep -R -n --include='*.swift' "$retired" Sources; then
    echo "error: retired M7 migration authority remains in production sources: $retired" >&2
    exit 1
  fi
done

if grep -R -n --include='*.swift' -E '@MainActor|^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI|Combine)([[:space:]]|$)' "$runtime_sources"; then
  echo "error: RepoPromptDomainRuntime must have zero domain-owned MainActor or UI dependencies" >&2
  exit 1
fi

canonical_file="$runtime_sources/MCPDomainCanonicalToolDefinitions.swift"
if [[ ! -f "$canonical_file" ]]; then
  echo "error: missing canonical Swift tool definitions" >&2
  exit 1
fi

if find "$runtime_sources" "$direct_sources" -type f \( -iname '*tool*manifest*.json' -o -iname '*schema*manifest*.json' \) -print -quit | grep -q .; then
  echo "error: headless canonical schemas must not be copied into a resource manifest" >&2
  exit 1
fi

if ! grep -q 'MCPStdioServerTransport' "$direct_sources/DirectHeadlessMCPService.swift"; then
  echo "error: headless backend must use its terminal-aware bounded stdio transport" >&2
  exit 1
fi

if grep -E -q '(^|[^[:alnum:]_])StdioTransport\(' "$direct_sources/DirectHeadlessMCPService.swift"; then
  echo "error: headless backend must not install the SDK stdio dispatcher" >&2
  exit 1
fi

canonical_workspace_service="$runtime_sources/MCPDomainCanonicalWorkspaceService.swift"
direct_workspace_adapter="$direct_sources/DirectHeadlessWorkspaceBackends.swift"
if [[ ! -f "$canonical_workspace_service" ]] \
  || ! grep -q 'MCPDomainCanonicalWorkspaceService' "$direct_workspace_adapter"; then
  echo "error: direct workspace tools must adapt the canonical domain workspace service" >&2
  exit 1
fi

if grep -E -n 'String\(contentsOf|FileManager\.default\.enumerator|NSRegularExpression' "$direct_workspace_adapter"; then
  echo "error: direct workspace adapter must not duplicate canonical read/search/tree implementations" >&2
  exit 1
fi

capability_adapters="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAppPhysicalCapabilityAdapters.swift"
for family in Execution Context Selection Files Prompt; do
  if ! grep -q "struct $family" "$capability_adapters"; then
    echo "error: missing typed app physical capability family: $family" >&2
    exit 1
  fi
done

if grep -q '@dynamicMemberLookup' "$capability_adapters"; then
  echo "error: physical capability families must not expose dynamic-member forwarding" >&2
  exit 1
fi

code_structure_query_core="Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPCodeStructureQuery.swift"
if [[ ! -f "$code_structure_query_core" ]] \
  || ! grep -q 'struct MCPCodeStructureQueryOrchestrator' "$code_structure_query_core"; then
  echo "error: missing app-independent get_code_structure query core" >&2
  exit 1
fi
if grep -n -E '@MainActor|MainActor\.|ViewModel|WindowState|^[[:space:]]*import[[:space:]]+(AppKit|SwiftUI|Combine)([[:space:]]|$)' \
  "$code_structure_query_core"; then
  echo "error: the get_code_structure query core must stay actor-free and hold no window or UI model" >&2
  exit 1
fi

route_settlement_core="$runtime_sources/ContextBuilder/ContextBuilderRouteSettlementRace.swift"
if [[ ! -f "$route_settlement_core" ]] \
  || ! grep -q 'enum ContextBuilderRouteSettlementRace' "$route_settlement_core"; then
  echo "error: missing shared Context Builder route/stream settlement core" >&2
  exit 1
fi
if grep -R -n --include='*.swift' -E 'AIStreamResult|ViewModel|WindowState|MCPBootstrapLease' \
  "$runtime_sources/ContextBuilder"; then
  echo "error: the Context Builder route settlement core must stay provider-, lease-, and UI-neutral" >&2
  exit 1
fi
if grep -R -n --include='*.swift' 'ContextBuilderRouteSettlementCoordinator' Sources; then
  echo "error: the retired MainActor route settlement coordinator must not return" >&2
  exit 1
fi
if ! grep -q 'ContextBuilderRouteSettlementRace.run' \
  Sources/RepoPrompt/Features/ContextBuilder/ViewModels/ContextBuilderAgentViewModel.swift; then
  echo "error: nested discovery must settle its route/stream race through the shared core" >&2
  exit 1
fi

discovery_core="$runtime_sources/ContextBuilder/ContextBuilderDiscoveryEngine.swift"
if [[ ! -f "$discovery_core" ]] \
  || ! grep -q 'struct ContextBuilderDiscoveryEngine' "$discovery_core"; then
  echo "error: missing shared headless Context Builder discovery core" >&2
  exit 1
fi
if grep -n -E 'applyFileEdits|manageFiles|DomainMutationPhysicalCapability|admitPhysicalTargets|workspaceStore' \
  "$runtime_sources"/ContextBuilder/ContextBuilderDiscovery*.swift \
  "$runtime_sources/ContextBuilder/ContextBuilderFrozenWorkspace.swift"; then
  echo "error: the discovery core must stay read-only; only the host committer port may write the selection" >&2
  exit 1
fi
if ! grep -q 'ContextBuilderDiscoveryEngine' Sources/RepoPromptMCP/DirectHeadlessContextDiscovery.swift \
  || ! grep -q 'purpose: .contextDiscovery' Sources/RepoPromptMCP/DirectHeadlessContextDiscovery.swift; then
  echo "error: direct-headless discovery must run through the shared core with the read-only discovery purpose" >&2
  exit 1
fi
# M18: discovery plans mint no child-launch carrier until the post-commit Oracle handoff, and the
# Oracle step after a commit is always settled with what was committed.
if [[ "$(grep -c 'preparation: .atHandoff' Sources/RepoPromptMCP/DirectHeadlessOracleAdapter.swift)" -lt 2 ]] \
  || ! grep -q 'let pin = Self.committedContextPin(outcome)' Sources/RepoPromptMCP/DirectHeadlessCapabilityBackends.swift \
  || ! grep -q 'handoff.prepare(pinnedTo: pin)' Sources/RepoPromptMCP/DirectHeadlessCapabilityBackends.swift \
  || ! grep -q 'settlementAfterDiscovery' Sources/RepoPromptMCP/DirectHeadlessCapabilityBackends.swift; then
  echo "error: discovery must prepare Oracle carriers at the post-commit handoff and settle post-commit failures" >&2
  exit 1
fi
# M19: handoff carriers are minted only for the exact committed context authority.
if ! grep -q 'try pin.validate(handle)' Sources/RepoPromptMCP/DirectHeadlessChildEndpoint.swift; then
  echo "error: the child-launch coordinator must refuse a handoff whose current context is not the pinned one" >&2
  exit 1
fi
# M20: the Oracle processes launch in that same pinned context (working directory included),
# revalidated at the launch, so process directory and token authority are one context.
if [[ "$(grep -c 'launchPin: pin' Sources/RepoPromptMCP/DirectHeadlessCapabilityBackends.swift)" -lt 2 ]] \
  || ! grep -q 'context.pinnedLaunchSnapshot(' Sources/RepoPromptMCP/DirectHeadlessProviderCoordinator.swift \
  || ! grep -q 'Mismatch(pinnedLaunchError: error)' Sources/RepoPromptMCP/DirectHeadlessCapabilityBackends.swift; then
  echo "error: discovered Oracle launches must run in the pinned committed context and settle pre-launch changes" >&2
  exit 1
fi

if grep -R -n --include='MCP*ToolProvider.swift' \
  -E 'dependencies:[[:space:]]+MCPAppPhysicalCapabilityAdapters([[:space:],?)]|$)' \
  Sources/RepoPrompt/Infrastructure/MCP/WindowTools; then
  echo "error: providers must receive only explicit physical capability families" >&2
  exit 1
fi

if grep -E -q 'stored_(dependency|family)_(count|families)' Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json; then
  echo "error: the retired flat closure dependency bag contract must not return" >&2
  exit 1
fi

if ! grep -q 'MCPDomainReadToolProvider' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift"; then
  echo "error: standalone composition must reuse the canonical read provider" >&2
  exit 1
fi

if ! grep -q 'protectedMutationProvider.protectedBinding' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift" \
  || ! grep -q 'longRunningToolProvider.wrapping' "$runtime_sources/MCPDomainStandaloneCapabilityProvider.swift"; then
  echo "error: standalone bindings must install both security decorators" >&2
  exit 1
fi

echo "Headless runtime guardrails passed."
